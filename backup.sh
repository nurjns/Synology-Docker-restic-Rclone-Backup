#!/bin/bash
#
# restic Backup Script - nurjns
# Version 1.0.0 - 2026-08-31
#
# Stops the containers per Docker Compose project via the Synology
# Container Manager API, verifies that via the container label, backs up
# the compose directory + data directory under one tag per project,
# starts only the projects that were running before the backup, and
# sends a status email with the full log.

set -o pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Project names = folder name under DOCKER_BASE AND COMPOSE_BASE AND the
# value of the com.docker.compose.project label AND the name shown in
# Container Manager. Check with:
# sudo docker ps --format '{{.Label "com.docker.compose.project"}} {{.Names}}'
PROJECTS=(
	project1
	project2
	project3
)

COMPOSE_BASE="/volume1/docker" # docker-compose.yml (Container Manager)
DOCKER_BASE="/volume1/docker-data" # Docker data / bind mounts

RESTIC_DIR="/volume1/homes/admin/restic"
SECRETS_DIR="$RESTIC_DIR/secrets"
LOGS_DIR="$RESTIC_DIR/logs"

RESTIC_BIN="$RESTIC_DIR/restic"
RCLONE_BIN="$RESTIC_DIR/rclone"
RCLONE_CONF="$SECRETS_DIR/rclone.conf"

# Synology's built-in curl only supports http/https, not smtp
CURL_SMTP_BIN="$RESTIC_DIR/curl-smtp"

RCLONE_REMOTE="remote_name"
RCLONE_REPO_PATH="path/to/repository"
export RESTIC_REPOSITORY="rclone:${RCLONE_REMOTE}:${RCLONE_REPO_PATH}"
export RESTIC_PASSWORD_FILE="$SECRETS_DIR/restic_password"

# number of snapshots to keep per tag (i.e. per project), older ones are pruned
RESTIC_KEEP_LAST=12

RESTIC_OPTS=(-o rclone.program="$RCLONE_BIN" -o rclone.args="--config $RCLONE_CONF serve restic --stdio --b2-hard-delete")

# always backed up in addition: the restic directory itself + loose .sh
# files directly under COMPOSE_BASE (not belonging to any project)
EXTRA_BACKUP_TAG="restic-config"

# used in the email subject: [Success]/[Failed] MAIL_SUBJECT_TAG
MAIL_SUBJECT_TAG="restic-weekly-backup"

# SMTP server
SMTP_ENABLED=1 # send status emails? 1 = enabled, 0 = disabled
SMTP_HOST="mailhost"
SMTP_PORT="587"
SMTP_USER="smtpuser@example.com"
SMTP_FROM="sender@example.com"
SMTP_TO="receiver@example.com"
SMTP_PASS_FILE="$SECRETS_DIR/smtp_password"

LOCKFILE="$RESTIC_DIR/backup.lock"

mkdir -p "$LOGS_DIR"
LOGFILE="$LOGS_DIR/backup-$(date +%Y-%m-%d_%H-%M-%S).log"

# clean up old logs (older than 365 days)
find "$LOGS_DIR" -name 'backup-*.log' -mtime +365 -delete 2>/dev/null

OVERALL_STATUS="Success"
FAILED_PROJECTS=()

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

run_restic() {
	"$RESTIC_BIN" "${RESTIC_OPTS[@]}" "$@"
}

project_running_ids() {
	local project="$1"
	docker ps -a --filter "label=com.docker.compose.project=$project" --filter 'status=running' --format '{{.ID}}'
}

project_all_states() {
	local project="$1"
	docker ps -a --filter "label=com.docker.compose.project=$project" --format '{{.Names}}: {{.State}}'
}

# all containers of a project, regardless of status
project_all_ids() {
	local project="$1"
	docker ps -a --filter "label=com.docker.compose.project=$project" --format '{{.ID}}'
}

# look up the Container Manager project UUID by name
project_id_lookup() {
	local project="$1"
	synowebapi --exec api=SYNO.Docker.Project version=1 method=list 2>/dev/null | jq -r --arg name "$project" '.data[] | select(.name == $name) | .id'
}

project_api_stop() {
	local id="$1"
	synowebapi --exec api=SYNO.Docker.Project version=1 method=stop "id=\"$id\""
}

project_api_start() {
	local id="$1"
	synowebapi --exec api=SYNO.Docker.Project version=1 method=start "id=\"$id\""
}

send_mail() {
	local subject="$1"
	local mailfile="/tmp/restic-mail-$$.txt"

	if [ "$SMTP_ENABLED" != '1' ]; then
		log "Mail sending disabled (SMTP_ENABLED=$SMTP_ENABLED), skipping."
		return 0
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

# Lock: prevents two runs from stopping/backing up containers at the same time
if [ -e "$LOCKFILE" ]; then
	OLD_PID="$(cat "$LOCKFILE" 2>/dev/null)"
	if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
		log "Backup is already running (PID $OLD_PID), aborting."
		exit 1
	fi
	log "Found stale lock file with dead PID $OLD_PID, ignoring it."
fi
echo $$ > "$LOCKFILE"

for cmd in synowebapi jq; do
	if ! command -v "$cmd" > /dev/null 2>&1; then
		log "FATAL: required command '$cmd' was not found."
		send_mail "[Failed] $MAIL_SUBJECT_TAG"
		rm -f "$LOCKFILE"
		exit 1
	fi
done

# project UUIDs and their original running state, also used by restart_all
declare -A PROJECT_IDS
declare -A WAS_RUNNING

# always start the containers again at the end, even after abort/error
restart_all() {
	local project id ids cid

	for project in "${!WAS_RUNNING[@]}"; do
		id="${PROJECT_IDS[$project]:-}"
		if [ -z "$id" ]; then
			log "WARNING: no project ID known for $project, cannot start it via the API."
			continue
		fi

		log "Starting $project (ID $id) ..."
		project_api_start "$id" >> "$LOGFILE" 2>&1

		# fallback in case the API reports ok but nothing is actually running
		if [ -z "$(project_running_ids "$project")" ]; then
			ids="$(project_all_ids "$project")"
			if [ -n "$ids" ]; then
				log "NOTE: the API did not start $project, starting the containers directly by ID."
				for cid in $ids; do
					if docker start "$cid" >> "$LOGFILE" 2>&1; then
						log "  started: $cid"
					else
						log "  ERROR starting $cid"
					fi
				done
			fi
		fi
	done
}

cleanup_on_exit() {
	restart_all
	rm -f "$LOCKFILE"
}
trap cleanup_on_exit EXIT

# ---------------------------------------------------------------------------
# Stop projects + actually verify via label + back them up
# ---------------------------------------------------------------------------

for project in "${PROJECTS[@]}"; do
	compose_dir="$COMPOSE_BASE/$project"
	data_dir="$DOCKER_BASE/$project"

	if [ ! -d "$compose_dir" ]; then
		log "ERROR: compose directory $compose_dir does not exist, project $project cannot be controlled - skipping entirely."
		FAILED_PROJECTS+=("$project (compose directory missing)")
		continue
	fi

	targets=("$compose_dir")
	if [ -d "$data_dir" ]; then
		targets+=("$data_dir")
	else
		log "WARNING: data directory $data_dir does not exist (project $project), will only be partially backed up."
		FAILED_PROJECTS+=("$project (data directory missing)")
	fi

	if [ -n "$(project_running_ids "$project")" ]; then
		WAS_RUNNING["$project"]=1

		pid="$(project_id_lookup "$project")"
		if [ -z "$pid" ]; then
			log "ERROR: could not determine the Container Manager project ID for '$project'."
			FAILED_PROJECTS+=("$project (project ID not found)")
			tries=6
		else
			PROJECT_IDS["$project"]="$pid"
			log "Stopping project $project (ID $pid) ..."
			project_api_stop "$pid" >> "$LOGFILE" 2>&1

			# fallback in case the API reports ok but something is still running
			if [ -n "$(project_running_ids "$project")" ]; then
				log "NOTE: the API did not stop $project, stopping the containers directly by ID."
				for id in $(project_running_ids "$project"); do
					if docker stop "$id" >> "$LOGFILE" 2>&1; then
						log "  stopped: $id"
					else
						log "  ERROR stopping $id"
					fi
				done
			fi

			tries=0
			while [ -n "$(project_running_ids "$project")" ]; do
				tries=$((tries + 1))
				if [ "$tries" -ge 6 ]; then
					log "ERROR: project $project is still running after the stop attempt!"
					log "Container status $project: $(project_all_states "$project")"
					FAILED_PROJECTS+=("$project (did not stop)")
					break
				fi
				sleep 5
			done
		fi
	else
		log "Project $project was already stopped, nothing to do."
		tries=0
	fi

	if [ "$tries" -lt 6 ]; then
		log "Project $project stopped. Backing up: ${targets[*]}"
		if ! run_restic backup "${targets[@]}" --tag "$project" >> "$LOGFILE" 2>&1; then
			log "ERROR: restic backup for $project failed."
			FAILED_PROJECTS+=("$project (backup failed)")
		fi
	else
		log "Project $project is still running, will NOT be backed up."
	fi
done

# ---------------------------------------------------------------------------
# Extra backup: the restic directory itself + loose .sh files under COMPOSE_BASE
# ---------------------------------------------------------------------------

shopt -s nullglob
EXTRA_TARGETS=("$RESTIC_DIR")
EXTRA_TARGETS+=("$COMPOSE_BASE"/*.sh)
shopt -u nullglob

log "Backup: extra (tag: $EXTRA_BACKUP_TAG) - ${EXTRA_TARGETS[*]}"
if ! run_restic backup "${EXTRA_TARGETS[@]}" --tag "$EXTRA_BACKUP_TAG" >> "$LOGFILE" 2>&1; then
	log "ERROR: restic backup for tag $EXTRA_BACKUP_TAG failed."
	OVERALL_STATUS="Failed"
fi

# ---------------------------------------------------------------------------
# Retention - handled per tag so projects don't affect each other
# ---------------------------------------------------------------------------

ALL_TAGS=("${PROJECTS[@]}" "$EXTRA_BACKUP_TAG")
for tag in "${ALL_TAGS[@]}"; do
	log "Forget/prune tag $tag (--keep-last $RESTIC_KEEP_LAST) ..."
	if ! run_restic forget --tag "$tag" --keep-last "$RESTIC_KEEP_LAST" --prune >> "$LOGFILE" 2>&1; then
		log "ERROR: forget/prune for tag $tag failed."
		OVERALL_STATUS="Failed"
	fi
done

# ---------------------------------------------------------------------------
# Check
# ---------------------------------------------------------------------------

log "restic check ..."
if ! run_restic check >> "$LOGFILE" 2>&1; then
	log "ERROR: restic check failed."
	OVERALL_STATUS="Failed"
fi

if [ "$(date +%d)" -le 7 ]; then
	log "Monthly data check (read-data-subset=5%) ..."
	if ! run_restic check --read-data-subset=5% >> "$LOGFILE" 2>&1; then
		log "ERROR: restic check --read-data-subset failed."
		OVERALL_STATUS="Failed"
	fi
fi

# ---------------------------------------------------------------------------
# Start the containers again (explicitly, so it shows up in the mailed log)
# ---------------------------------------------------------------------------

restart_all
trap - EXIT
rm -f "$LOCKFILE"

# ---------------------------------------------------------------------------
# Status / mail
# ---------------------------------------------------------------------------

if [ "${#FAILED_PROJECTS[@]}" -gt 0 ]; then
	OVERALL_STATUS="Failed"
	log "Failed projects: ${FAILED_PROJECTS[*]}"
fi

log "Overall status: $OVERALL_STATUS"
log "Log saved at: $LOGFILE"
send_mail "[$OVERALL_STATUS] $MAIL_SUBJECT_TAG"

if [ "$OVERALL_STATUS" = 'Failed' ]; then
	exit 1
fi