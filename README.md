# Synology Docker restic Rclone Backup

Back up Docker Compose projects on a Synology NAS with [restic](https://restic.net/) and [Rclone](https://rclone.org/), controlled entirely through the Synology Container Manager API — no SSH `docker compose` calls, no dependency on cron's environment. Includes an interactive restore script, a self-update script for the binaries, and a small CLI helper for ad-hoc restic commands.

## Why

Synology's DSM ships a `curl` without SMTP support and a `docker compose` CLI that can silently disagree with what Container Manager actually has running. This toolkit works around both: it stops/starts projects through the official `SYNO.Docker.Project` API (with a raw `docker stop`/`docker start` fallback), verifies the real container state via `docker ps` before touching any files, and ships its own statically linked `curl` for sending status emails.

## Features

- Stops each Docker Compose project via the Container Manager API, **verifies** via `docker ps` that containers are actually down before backing up
- Falls back to `docker stop`/`docker start` by container ID if the API call doesn't do what it should
- Only restarts projects that were actually running before the backup — a project you stopped on purpose stays stopped
- One restic snapshot per project, tagged with the project name; retention (`--keep-last`) is enforced **per tag**, so a busy project doesn't crowd a quiet one out of its history
- Backs up both the data directory and the Compose directory for each project, plus the script's own directory and any loose `.sh` files, so the whole toolkit is recoverable from the backup itself
- Lock file with a stale-PID check, so overlapping runs can't stop each other's containers
- Status email (`[Success]`/`[Failed]`) with the full run log attached, sent via a self-contained static `curl` build (works around DSM's SMTP-less `curl`)
- Monthly `restic check --read-data-subset=5%` in addition to the regular metadata check
- Interactive restore: pick a service, pick a snapshot by date, choose what to restore — existing directories are **renamed**, never deleted
- Self-update script for `restic`/`rclone`/`curl` with automatic rollback if an update breaks

## Repository layout

| File | Purpose |
|---|---|
| `backup.sh` | Scheduled backup run (DSM Task Scheduler) |
| `restore.sh` | Interactive restore, run manually over SSH |
| `restic-cli.sh` | Thin wrapper so you don't have to retype the restic flags for ad-hoc commands |
| `update.sh` | Updates the `restic`/`rclone`/`curl` binaries, with rollback |

All four are meant to live together in one directory on the NAS, e.g. `/volume1/homes/admin/restic/`.

## Requirements

- DSM 7 with Container Manager (Docker) installed
- SSH access with an administrator account, root via `sudo -i`
- `jq` (used to resolve a project name to its Container Manager UUID) — check with `command -v jq`; if missing, install it via Entware or a static build
- An Rclone-supported remote (OneDrive, Backblaze B2, S3, ...) with credentials already set up
- Each Docker service organized as: one Compose directory under `COMPOSE_BASE/<project>` and, optionally, one data/bind-mount directory under `DOCKER_BASE/<project>`

## Installation

All binaries are installed into the script directory itself rather than `/usr/local/bin`, since that can be wiped by major DSM upgrades.

```bash
mkdir -p /volume1/homes/admin/restic
cd /volume1/homes/admin/restic
uname -m   # check your architecture before picking a download below
```

**restic** — grab the latest release from the [restic releases page](https://github.com/restic/restic/releases):
```bash
curl -LO https://github.com/restic/restic/releases/download/vX.Y.Z/restic_X.Y.Z_linux_amd64.bz2
bunzip2 restic_X.Y.Z_linux_amd64.bz2
mv restic_X.Y.Z_linux_amd64 restic
chmod +x restic
rm restic_X.Y.Z_linux_amd64.bz2
```

**Rclone** — from the [Rclone downloads page](https://rclone.org/downloads/):
```bash
curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip
7z x rclone-current-linux-amd64.zip
cp rclone-*-linux-amd64/rclone .
chmod +x rclone
rm rclone-current-linux-amd64.zip
```

**curl with SMTP support** — DSM's bundled `curl` is built without SMTP. Grab a static build from [stunnel/static-curl](https://github.com/stunnel/static-curl/releases) (use the **musl** variant):
```bash
TAG="$(curl -s https://api.github.com/repos/stunnel/static-curl/releases/latest | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[^"]*"//; s/".*//')"
curl -LO "https://github.com/stunnel/static-curl/releases/download/$TAG/curl-linux-x86_64-musl-$TAG.tar.xz"
tar -xf "curl-linux-x86_64-musl-$TAG.tar.xz"
mv curl curl-smtp
chmod +x curl-smtp
./curl-smtp --version | grep -i smtp   # must list "smtp smtps"
rm curl-linux-x86_64-musl-$TAG.tar.xz
```

## Secrets

All credentials live in one subdirectory, root-only:

```bash
mkdir -p /volume1/homes/admin/restic/secrets
cd /volume1/homes/admin/restic/secrets

rclone config --config ./rclone.conf     # set up your remote interactively
echo 'your-restic-repository-password' > restic_password
echo 'your-smtp-password' > smtp_password

cd ..
sudo chown -R root:root secrets
sudo chmod 700 secrets
sudo chmod 600 secrets/*
```

On Synology volumes, a plain `chmod` on a directory that carries a Windows-style ACL can leave a stale ACL entry that still grants access. Confirm with `ls -le secrets` — you want no `+` and no leftover ACL lines. If you see one, strip it explicitly:
```bash
sudo synoacltool -del /volume1/homes/admin/restic/secrets
```

The scripts run as root (via DSM Task Scheduler), so root-only permissions on `secrets/` are intentional — everyday admin accounts don't need, and shouldn't have, read access to these files.

## SMTP setup

The included static `curl` talks SMTP directly — no mail relay or MTA needed. Fill in your own server:

```bash
SMTP_HOST="mailhost"
SMTP_PORT="587"
SMTP_USER="smtpuser@example.com"
SMTP_FROM="sender@example.com"
SMTP_TO="receiver@example.com"
```

Test it in isolation before trusting the full backup run:
```bash
printf 'From: sender@example.com\nTo: receiver@example.com\nSubject: Test\n\nTest mail\n' > /tmp/test-mail.txt
./curl-smtp -v --url "smtp://mailhost:587" --ssl-reqd \
	--mail-from "sender@example.com" --mail-rcpt "receiver@example.com" \
	--upload-file /tmp/test-mail.txt --user "smtpuser@example.com:$(cat secrets/smtp_password)"
```
If your server uses implicit TLS instead of STARTTLS, use `smtps://host:465` instead of `smtp://host:587` with `--ssl-reqd`.

Don't want email at all? Set `SMTP_ENABLED=0` in `backup.sh` — `send_mail()` will log and skip instead of calling `curl`.

## Configuration

Edit the variables at the top of `backup.sh`:

```bash
PROJECTS=(
	project1
	project2
	project3
)

COMPOSE_BASE="/volume1/docker"        # where each project's compose.yaml lives
DOCKER_BASE="/volume1/docker-data"    # where each project's data/bind mounts live

RCLONE_REMOTE="remote_name"           # must match a remote in secrets/rclone.conf
RCLONE_REPO_PATH="path/to/repository"

RESTIC_KEEP_LAST=12                   # snapshots kept per project tag
```

Each entry in `PROJECTS` must simultaneously be: the directory name under `COMPOSE_BASE`, the directory name under `DOCKER_BASE`, and the value Container Manager uses as the project name. Check the latter with:
```bash
sudo docker ps --format '{{.Label "com.docker.compose.project"}} {{.Names}}'
```

Initialize the repository once:
```bash
./restic -o rclone.program=/volume1/homes/admin/restic/rclone \
	-o rclone.args='--config /volume1/homes/admin/restic/secrets/rclone.conf serve restic --stdio --b2-hard-delete' \
	-r rclone:remote_name:path/to/repository init
```

`restore.sh`, `restic-cli.sh` and `update.sh` each have their own copy of `RESTIC_DIR`/`RCLONE_REMOTE`/`RCLONE_REPO_PATH` at the top — keep them in sync with `backup.sh`.

## Scheduling

Use DSM's Task Scheduler rather than a hand-edited crontab:

*Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script*
- User: **root**
- Schedule: for example weekly, at night
- Custom script: `/volume1/homes/admin/restic/backup.sh`

Running as root avoids two separate headaches: your admin account doesn't need to be in the `docker` group, and you don't need `NOPASSWD` sudo rules for an unattended job.

Set up `update.sh` the same way, monthly, at a different time than the backup run (it checks `backup.lock` and refuses to run concurrently with a backup).

## Usage

**Check backups:**
```bash
sudo ./restic-cli.sh snapshots
sudo ./restic-cli.sh snapshots --tag project1
sudo ./restic-cli.sh stats
```

**Restore:**
```bash
sudo ./restore.sh
```
Walks you through: what to restore (a service, or the toolkit's own config) → which snapshot → which directories → confirmation. Existing directories are renamed to `<name>_<timestamp>`, never deleted, so a bad restore doesn't cost you your last-known-good data. If the target service's containers are still running, the script offers to stop them for you before continuing.

**Update the binaries manually:**
```bash
sudo ./update.sh
```

## Disclaimer
This project is an independent open-source tool and is not affiliated, associated, authorized, endorsed by, or in any way officially connected with Synology Inc. or any of its subsidiaries or affiliates.
