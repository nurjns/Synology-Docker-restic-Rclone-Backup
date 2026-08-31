#!/bin/bash
#
# restic Backup Update Script
# Version 1.0.0 - 2026-08-31
#
# Updates restic, rclone and the static curl binary.
# The previous binaries are backed up as <name>.old first. If an updated
# binary can no longer be executed, the previous version is restored
# automatically.
#
# Execution: as root (DSM Task Scheduler, user-defined script)

set -o pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

RESTIC_DIR="/volume1/homes/admin/restic"
SECRETS_DIR="$RESTIC_DIR/secrets"
LOGS_DIR="$RESTIC_DIR/logs"

RESTIC_BIN="$RESTIC_DIR/restic"
RCLONE_BIN="$RESTIC_DIR/rclone"
CURL_SMTP_BIN="$RESTIC_DIR/curl-smtp"

RCLONE_REMOTE="remote_name"
RCLONE_REPO_PATH="path/to/repository"

# source for the static curl binary
CURL_REPO='stunnel/static-curl'

# used in the email subject: [Success]/[Failed] MAIL_SUBJECT_TAG
MAIL_SUBJECT_TAG="restic-update"

SMTP_HOST="mailhost"
SMTP_PORT="587"
SMTP_USER="smtpuser@example.com"
SMTP_FROM="sender@example.com"
SMTP_TO="receiver@example.com"
SMTP_PASS_FILE="$SECRETS_DIR/smtp_password"

BACKUP_LOCKFILE="$RESTIC_DIR/backup.lock"

mkdir -p "$LOGS_DIR"
LOGFILE="$LOGS_DIR/update-$(date +%Y-%m-%d_%H-%M-%S).log"

find "$LOGS_DIR" -name 'update-*.log' -mtime +365 -delete 2>/dev/null

OVERALL_STATUS="Success"
CHANGES=()

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

send_mail() {
	local subject="$1"
	local mailfile="/tmp/update-mail-$$.txt"

	if [ ! -x "$CURL_SMTP_BIN" ]; then
		log "No working curl-smtp available - cannot send mail."
		return 1
	fi

	{
		echo "From: $SMTP_FROM"
		echo "To: $SMTP_TO"
		echo "Subject: $subject"
		echo "Content-Type: text/plain; charset=UTF-8"
		echo
		cat "$LOGFILE"
	} > "$mailfile"

	"$CURL_SMTP_BIN" --silent --show-error \
		--url "smtp://$SMTP_HOST:$SMTP_PORT" \
		--ssl-reqd \
		--mail-from "$SMTP_FROM" \
		--mail-rcpt "$SMTP_TO" \
		--upload-file "$mailfile" \
		--user "$SMTP_USER:$(cat "$SMTP_PASS_FILE")"

	rm -f "$mailfile"
}

# Checks whether a binary runs. If not, the .old backup is restored.
verify_or_rollback() {
	local bin="$1"
	local name="$2"
	shift 2

	if "$bin" "$@" > /dev/null 2>&1; then
		return 0
	fi

	log "ERROR: $name can no longer be executed after the update."

	if [ -f "${bin}.old" ]; then
		if mv "${bin}.old" "$bin"; then
			log "Rolled back to the previous version of $name."
		else
			log "ERROR: rollback of $name failed - please check manually."
		fi
	else
		log "ERROR: no backup ${bin}.old available - $name is broken."
	fi

	OVERALL_STATUS="Failed"
	return 1
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
	echo "Please run as root."
	exit 1
fi

log "=== Update run started ==="

if [ -e "$BACKUP_LOCKFILE" ]; then
	OLD_PID="$(cat "$BACKUP_LOCKFILE" 2>/dev/null)"
	if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
		log "ABORTED: a backup is currently running (PID $OLD_PID)."
		send_mail "[Failed] $MAIL_SUBJECT_TAG"
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# restic
# ---------------------------------------------------------------------------

log "--- restic ---"

if [ ! -x "$RESTIC_BIN" ]; then
	log "ERROR: $RESTIC_BIN is missing."
	OVERALL_STATUS="Failed"
else
	RESTIC_OLD_VER="$("$RESTIC_BIN" version 2>/dev/null | awk '{print $2}')"
	log "Current version: $RESTIC_OLD_VER"

	cp -p "$RESTIC_BIN" "${RESTIC_BIN}.old"

	# self-update verifies the GPG signature of the release files itself
	if "$RESTIC_BIN" self-update >> "$LOGFILE" 2>&1; then
		if verify_or_rollback "$RESTIC_BIN" 'restic' version; then
			RESTIC_NEW_VER="$("$RESTIC_BIN" version 2>/dev/null | awk '{print $2}')"
			if [ "$RESTIC_OLD_VER" = "$RESTIC_NEW_VER" ]; then
				log "Already up to date ($RESTIC_NEW_VER)."
				rm -f "${RESTIC_BIN}.old"
			else
				log "Updated: $RESTIC_OLD_VER -> $RESTIC_NEW_VER"
				CHANGES+=("restic $RESTIC_OLD_VER -> $RESTIC_NEW_VER")
			fi
		fi
	else
		log "ERROR: 'restic self-update' failed."
		rm -f "${RESTIC_BIN}.old"
		OVERALL_STATUS="Failed"
	fi
fi

# ---------------------------------------------------------------------------
# rclone
# ---------------------------------------------------------------------------

log "--- rclone ---"

if [ ! -x "$RCLONE_BIN" ]; then
	log "ERROR: $RCLONE_BIN is missing."
	OVERALL_STATUS="Failed"
else
	RCLONE_OLD_VER="$("$RCLONE_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
	log "Current version: $RCLONE_OLD_VER"

	cp -p "$RCLONE_BIN" "${RCLONE_BIN}.old"

	# selfupdate verifies the checksum and signature itself
	if "$RCLONE_BIN" selfupdate >> "$LOGFILE" 2>&1; then
		if verify_or_rollback "$RCLONE_BIN" 'rclone' version; then
			RCLONE_NEW_VER="$("$RCLONE_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
			if [ "$RCLONE_OLD_VER" = "$RCLONE_NEW_VER" ]; then
				log "Already up to date ($RCLONE_NEW_VER)."
				rm -f "${RCLONE_BIN}.old"
			else
				log "Updated: $RCLONE_OLD_VER -> $RCLONE_NEW_VER"
				CHANGES+=("rclone $RCLONE_OLD_VER -> $RCLONE_NEW_VER")
			fi
		fi
	else
		log "ERROR: 'rclone selfupdate' failed."
		rm -f "${RCLONE_BIN}.old"
		OVERALL_STATUS="Failed"
	fi
fi

# ---------------------------------------------------------------------------
# curl-smtp (no self-update available, so this goes through the GitHub API)
# ---------------------------------------------------------------------------

log "--- curl-smtp ---"

case "$(uname -m)" in
	x86_64)
		CURL_ARCH='x86_64'
		;;
	aarch64|arm64)
		CURL_ARCH='aarch64'
		;;
	*)
		CURL_ARCH=''
		log "ERROR: unknown architecture $(uname -m) - skipping curl-smtp."
		OVERALL_STATUS="Failed"
		;;
esac

if [ -n "$CURL_ARCH" ]; then
	if [ -x "$CURL_SMTP_BIN" ]; then
		CURL_OLD_VER="$("$CURL_SMTP_BIN" --version 2>/dev/null | head -1 | awk '{print $2}')"
	else
		CURL_OLD_VER='(not present)'
	fi
	log "Current version: $CURL_OLD_VER"

	# determine the latest version
	CURL_TAG="$(curl -s "https://api.github.com/repos/$CURL_REPO/releases/latest" | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[^"]*"//; s/".*//')"

	if [ -z "$CURL_TAG" ]; then
		log "ERROR: could not determine the latest version (GitHub API unreachable?)."
		OVERALL_STATUS="Failed"
	elif [ "$CURL_TAG" = "$CURL_OLD_VER" ]; then
		log "Already up to date ($CURL_OLD_VER)."
	else
		log "Latest version: $CURL_TAG"

		TMPDIR_CURL="$(mktemp -d /tmp/curlupd.XXXXXX)"
		ARCHIVE="curl-linux-${CURL_ARCH}-musl-${CURL_TAG}.tar.xz"
		URL="https://github.com/$CURL_REPO/releases/download/$CURL_TAG/$ARCHIVE"

		log "Downloading $URL"
		if curl -sL -o "$TMPDIR_CURL/$ARCHIVE" "$URL" && tar -xf "$TMPDIR_CURL/$ARCHIVE" -C "$TMPDIR_CURL"; then
			NEW_CURL="$(find "$TMPDIR_CURL" -type f -name curl | head -1)"

			if [ -z "$NEW_CURL" ]; then
				log "ERROR: no curl file found in the archive."
				OVERALL_STATUS="Failed"
			elif ! "$NEW_CURL" --version 2>/dev/null | grep -qi 'smtp'; then
				log "ERROR: the new binary does not support SMTP - not adopting it."
				OVERALL_STATUS="Failed"
			else
				if [ -x "$CURL_SMTP_BIN" ]; then
					cp -p "$CURL_SMTP_BIN" "${CURL_SMTP_BIN}.old"
				fi

				if cp "$NEW_CURL" "$CURL_SMTP_BIN" && chmod +x "$CURL_SMTP_BIN"; then
					if verify_or_rollback "$CURL_SMTP_BIN" 'curl-smtp' --version; then
						log "Updated: $CURL_OLD_VER -> $CURL_TAG"
						CHANGES+=("curl-smtp $CURL_OLD_VER -> $CURL_TAG")
					fi
				else
					log "ERROR: could not install the new binary."
					OVERALL_STATUS="Failed"
				fi
			fi
		else
			log "ERROR: download or extraction failed."
			OVERALL_STATUS="Failed"
		fi

		rm -rf "$TMPDIR_CURL"
	fi
fi

# ---------------------------------------------------------------------------
# Final functional check
# ---------------------------------------------------------------------------

log "--- Functional check ---"

if [ -x "$RESTIC_BIN" ] && [ -x "$RCLONE_BIN" ]; then
	RCLONE_CONF="$SECRETS_DIR/rclone.conf"
	RESTIC_OPTS=(-o rclone.program="$RCLONE_BIN" -o rclone.args="--config $RCLONE_CONF serve restic --stdio --b2-hard-delete")
	export RESTIC_REPOSITORY="rclone:${RCLONE_REMOTE}:${RCLONE_REPO_PATH}"
	export RESTIC_PASSWORD_FILE="$SECRETS_DIR/restic_password"

	if "$RESTIC_BIN" "${RESTIC_OPTS[@]}" snapshots --last > /dev/null 2>&1; then
		log "OK: repository still reachable."
	else
		log "ERROR: repository not reachable after the update."
		OVERALL_STATUS="Failed"
	fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

if [ "${#CHANGES[@]}" -eq 0 ]; then
	log "No updates were made."
else
	log "Updates: ${CHANGES[*]}"
	log "The old binaries are kept alongside as *.old and can be removed"
	log "after a successful backup run."
fi

log "Overall status: $OVERALL_STATUS"
send_mail "[$OVERALL_STATUS] $MAIL_SUBJECT_TAG"

if [ "$OVERALL_STATUS" = 'Failed' ]; then
	exit 1
fi