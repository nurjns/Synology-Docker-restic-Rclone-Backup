#!/bin/bash
#
# restic Restore Script - nurjns
# Version 1.0.0 - 2026-08-31
#
# Restores a service (data directory, optionally the compose directory) or
# the restic configuration from a snapshot.
#
# Existing directories are NOT deleted, only renamed to
#   <directory>_<timestamp>
# and must be removed manually after a successful check.
#
# Execution: as root (sudo -i), interactively in the SSH shell.

set -o pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

COMPOSE_BASE="/volume1/docker" # docker-compose.yml (Container Manager)
DOCKER_BASE="/volume1/docker-data" # Docker data / bind mounts

RESTIC_DIR="/volume1/homes/admin/restic"
SECRETS_DIR="$RESTIC_DIR/secrets"

RESTIC_BIN="$RESTIC_DIR/restic"
RCLONE_BIN="$RESTIC_DIR/rclone"
RCLONE_CONF="$SECRETS_DIR/rclone.conf"

RCLONE_REMOTE="remote_name"
RCLONE_REPO_PATH="path/to/repository"
export RESTIC_REPOSITORY="rclone:${RCLONE_REMOTE}:${RCLONE_REPO_PATH}"
export RESTIC_PASSWORD_FILE="$SECRETS_DIR/restic_password"

RESTIC_OPTS=(-o rclone.program="$RCLONE_BIN" -o rclone.args="--config $RCLONE_CONF serve restic --stdio --b2-hard-delete")

EXTRA_BACKUP_TAG="restic-config"

BACKUP_LOCKFILE="$RESTIC_DIR/backup.lock"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"

RENAMED_DIRS=()

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

run_restic() {
	"$RESTIC_BIN" "${RESTIC_OPTS[@]}" "$@"
}

abort() {
	echo
	echo "ABORTED: $*"
	exit 1
}

ask_yes_no() {
	local prompt="$1"
	local answer

	while true; do
		read -r -p "$prompt [y/n]: " answer
		case "$answer" in
			[yY]|[yY][eE][sS])
				return 0
				;;
			[nN]|[nN][oO])
				return 1
				;;
			*)
				echo "Please enter 'y' or 'n'."
				;;
		esac
	done
}

ask_number() {
	local prompt="$1"
	local min="$2"
	local max="$3"
	local answer

	while true; do
		read -r -p "$prompt ($min-$max, 'q' to abort): " answer
		if [ "$answer" = 'q' ] || [ "$answer" = 'Q' ]; then
			abort "Aborted at the user's request."
		fi
		if ! echo "$answer" | grep -qE '^[0-9]+$'; then
			echo "Please enter a number."
			continue
		fi
		if [ "$answer" -lt "$min" ] || [ "$answer" -gt "$max" ]; then
			echo "Please enter a number between $min and $max."
			continue
		fi
		SELECTED_NUMBER="$answer"
		return 0
	done
}

project_running_ids() {
	local project="$1"
	docker ps -a --filter "label=com.docker.compose.project=$project" --filter 'status=running' --format '{{.ID}}'
}

project_all_states() {
	local project="$1"
	docker ps -a --filter "label=com.docker.compose.project=$project" --format '{{.Names}}: {{.State}}'
}

# Waits until the service is stopped - can stop it itself on request
require_project_stopped() {
	local project="$1"
	local compose_dir="$COMPOSE_BASE/$project"
	local running
	local tries
	local stopped
	local ids
	local id

	while true; do
		running="$(project_running_ids "$project")"
		if [ -z "$running" ]; then
			echo "OK: project '$project' is not running."
			return 0
		fi

		echo
		echo "Project '$project' is still running:"
		project_all_states "$project"
		echo
		echo "  1) Stop it now"
		echo "  2) I'll stop it manually - check again"
		echo "  3) Abort"
		echo

		ask_number "Choice" 1 3
		case "$SELECTED_NUMBER" in
			1)
				stopped='no'

				# preferred via compose, so compose is aware of the state
				if [ -d "$compose_dir" ]; then
					echo "Stopping '$project' via docker compose ..."
					if (cd "$compose_dir" && docker compose stop); then
						stopped='yes'
					else
						echo "NOTE: 'docker compose stop' failed (e.g. broken compose.yaml)."
					fi
				else
					echo "NOTE: $compose_dir does not exist."
				fi

				# fallback: stop the containers directly by ID, without compose
				if [ "$stopped" != 'yes' ]; then
					ids="$(project_running_ids "$project")"
					if [ -z "$ids" ]; then
						echo "No containers are running anymore."
					else
						echo "Fallback: stopping the containers directly by their IDs ..."
						for id in $ids; do
							if docker stop "$id" > /dev/null; then
								echo "  stopped: $id"
							else
								echo "  ERROR stopping $id"
							fi
						done
					fi
				fi

				# wait until it's really stopped, up to 60 seconds
				tries=0
				while [ -n "$(project_running_ids "$project")" ]; do
					tries=$((tries + 1))
					if [ "$tries" -ge 12 ]; then
						echo "Containers are still running after 60 seconds."
						break
					fi
					echo "Waiting ... ($((tries * 5))s)"
					sleep 5
				done
				;;
			2)
				echo
				echo "Stop it manually with:"
				echo "  cd $compose_dir && docker compose stop"
				echo
				read -r -p "Press ENTER once it's stopped ..." _
				;;
			3)
				abort "Project '$project' is still running - a restore would be dangerous."
				;;
		esac
	done
}

# Renames an existing directory instead of deleting it
rename_existing() {
	local dir="$1"
	local target

	[ -e "$dir" ] || return 0

	target="${dir}_${STAMP}"
	if [ -e "$target" ]; then
		abort "Target name '$target' already exists - please clean up manually."
	fi

	if ! mv "$dir" "$target"; then
		abort "Could not rename '$dir' to '$target'."
	fi

	echo "Renamed: $dir -> $target"
	RENAMED_DIRS+=("$target")
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
	abort "Please run as root (sudo -i)."
fi

for f in "$RESTIC_BIN" "$RCLONE_BIN"; do
	if [ ! -x "$f" ]; then
		abort "Binary missing or not executable: $f"
	fi
done

for f in "$RCLONE_CONF" "$RESTIC_PASSWORD_FILE"; do
	if [ ! -r "$f" ]; then
		abort "File missing or not readable: $f"
	fi
done

if ! command -v docker > /dev/null 2>&1; then
	abort "docker not found."
fi

if [ -e "$BACKUP_LOCKFILE" ]; then
	OLD_PID="$(cat "$BACKUP_LOCKFILE" 2>/dev/null)"
	if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
		abort "A backup is currently running (PID $OLD_PID). Please wait."
	fi
	echo "NOTE: found a stale lock file with dead PID $OLD_PID, ignoring it."
fi

echo "Checking connection to the repository ..."
if ! run_restic snapshots --last > /dev/null 2>&1; then
	abort "Repository unreachable or wrong password. Check the rclone token and $RESTIC_PASSWORD_FILE."
fi
echo "OK: repository reachable."

# ---------------------------------------------------------------------------
# Step 1: What should be restored?
# ---------------------------------------------------------------------------

echo
echo "==========================================================="
echo " restic Restore"
echo "==========================================================="
echo
echo "What should be restored?"
echo "  1) A service (data directory, optionally the compose directory)"
echo "  2) restic configuration ($RESTIC_DIR) and/or .sh scripts in $COMPOSE_BASE"
echo

ask_number "Choice" 1 2
RESTORE_MODE="$SELECTED_NUMBER"

# ---------------------------------------------------------------------------
# Step 2: Determine the tag
# ---------------------------------------------------------------------------

echo
echo "Loading existing tags from the repository ..."

ALL_TAGS="$(run_restic snapshots --json 2>/dev/null | tr ',' '\n' | grep -o '"tags":\[[^]]*\]' | sed 's/"tags":\[//; s/\]//; s/"//g' | tr ' ' '\n' | sort -u | grep -v '^$')"

if [ -z "$ALL_TAGS" ]; then
	# fallback without json parsing, in case the output looks different
	ALL_TAGS="$(run_restic snapshots 2>/dev/null | awk 'NF>3 {print $NF}' | grep -v -e '^Tags$' -e '^-' | sort -u)"
fi

if [ -z "$ALL_TAGS" ]; then
	abort "Could not find any tags in the repository. Check with: $RESTIC_DIR/restic-cli.sh snapshots"
fi

if [ "$RESTORE_MODE" = '2' ]; then
	SELECTED_TAG="$EXTRA_BACKUP_TAG"
	if ! echo "$ALL_TAGS" | grep -qx "$EXTRA_BACKUP_TAG"; then
		abort "No snapshot with tag '$EXTRA_BACKUP_TAG' exists."
	fi
	echo "Using tag: $SELECTED_TAG"
else
	# only offer service tags, hide restic-config
	SERVICE_TAGS="$(echo "$ALL_TAGS" | grep -vx "$EXTRA_BACKUP_TAG")"

	if [ -z "$SERVICE_TAGS" ]; then
		abort "No service snapshots exist in the repository."
	fi

	echo
	echo "Available services:"
	i=0
	TAG_LIST=()
	while IFS= read -r t; do
		i=$((i + 1))
		TAG_LIST+=("$t")
		printf '  %2d) %s\n' "$i" "$t"
	done <<< "$SERVICE_TAGS"
	echo

	ask_number "Select a service" 1 "$i"
	SELECTED_TAG="${TAG_LIST[$((SELECTED_NUMBER - 1))]}"
	echo "Selected: $SELECTED_TAG"
fi

# ---------------------------------------------------------------------------
# Step 3: Select the snapshot
# ---------------------------------------------------------------------------

echo
echo "Snapshots for tag '$SELECTED_TAG':"
echo

SNAP_RAW="$(run_restic snapshots --tag "$SELECTED_TAG" 2>/dev/null | grep -E '^[0-9a-f]{8} ')"

if [ -z "$SNAP_RAW" ]; then
	abort "No snapshots found for tag '$SELECTED_TAG'."
fi

i=0
SNAP_IDS=()
while IFS= read -r line; do
	i=$((i + 1))
	snap_id="$(echo "$line" | awk '{print $1}')"
	snap_date="$(echo "$line" | awk '{print $2" "$3}')"
	SNAP_IDS+=("$snap_id")
	printf '  %2d) %s   %s\n' "$i" "$snap_id" "$snap_date"
done <<< "$SNAP_RAW"
echo

ask_number "Select a snapshot (most recent last)" 1 "$i"
SELECTED_SNAP="${SNAP_IDS[$((SELECTED_NUMBER - 1))]}"
echo "Selected: snapshot $SELECTED_SNAP"

# ---------------------------------------------------------------------------
# Step 4: Determine the scope
# ---------------------------------------------------------------------------

RESTORE_PATHS=()
TARGET_DIRS=()

if [ "$RESTORE_MODE" = '1' ]; then
	PROJECT="$SELECTED_TAG"
	DATA_DIR="$DOCKER_BASE/$PROJECT"
	COMPOSE_DIR="$COMPOSE_BASE/$PROJECT"

	echo
	if ask_yes_no "Restore the data directory? ($DATA_DIR)"; then
		RESTORE_PATHS+=("$DATA_DIR")
		TARGET_DIRS+=("$DATA_DIR")
	fi

	if ask_yes_no "Restore the compose configuration? ($COMPOSE_DIR)"; then
		RESTORE_PATHS+=("$COMPOSE_DIR")
		TARGET_DIRS+=("$COMPOSE_DIR")
	fi

	if [ "${#RESTORE_PATHS[@]}" -eq 0 ]; then
		abort "Nothing selected."
	fi

	echo
	echo "Checking whether project '$PROJECT' is stopped ..."
	require_project_stopped "$PROJECT"
else
	echo
	if ask_yes_no "Restore the restic directory? ($RESTIC_DIR)"; then
		echo
		echo "NOTE: this script itself lives in $RESTIC_DIR."
		echo "The current directory will be renamed, but the running script"
		echo "stays in memory and finishes normally."
		echo
		if ask_yes_no "Continue anyway?"; then
			RESTORE_PATHS+=("$RESTIC_DIR")
			TARGET_DIRS+=("$RESTIC_DIR")
		fi
	fi

	if ask_yes_no "Restore .sh scripts in $COMPOSE_BASE?"; then
		RESTORE_SH='yes'
	fi

	if [ "${#RESTORE_PATHS[@]}" -eq 0 ] && [ "$RESTORE_SH" != 'yes' ]; then
		abort "Nothing selected."
	fi
fi

# ---------------------------------------------------------------------------
# Step 5: Summary and confirmation
# ---------------------------------------------------------------------------

echo
echo "==========================================================="
echo " Summary"
echo "==========================================================="
echo "  Snapshot : $SELECTED_SNAP (tag: $SELECTED_TAG)"
if [ "${#TARGET_DIRS[@]}" -gt 0 ]; then
	echo "  Folders  : ${TARGET_DIRS[*]}"
fi
if [ "$RESTORE_SH" = 'yes' ]; then
	echo "  Extra    : .sh files directly in $COMPOSE_BASE"
fi
echo
echo "  Existing directories will be renamed to <name>_${STAMP},"
echo "  NOT deleted."
echo

if ! ask_yes_no "Start the restore now?"; then
	abort "Aborted at the user's request."
fi

# ---------------------------------------------------------------------------
# Step 6: Rename directories and restore
# ---------------------------------------------------------------------------

for d in "${TARGET_DIRS[@]}"; do
	rename_existing "$d"
done

RESTORE_FAILED='no'

STAGING="$RESTIC_DIR/restore-staging_${STAMP}"

cleanup_staging() {
	if [ -d "$STAGING" ]; then
		rm -rf "$STAGING"
	fi
}
trap cleanup_staging EXIT

if [ "${#RESTORE_PATHS[@]}" -gt 0 ]; then
	INCLUDE_ARGS=()
	for p in "${RESTORE_PATHS[@]}"; do
		INCLUDE_ARGS+=(--include "$p")
	done

	if ! mkdir -p "$STAGING"; then
		abort "Could not create staging directory $STAGING."
	fi

	echo
	echo "Extracting the snapshot to $STAGING ..."
	if ! run_restic restore "$SELECTED_SNAP" --target "$STAGING" "${INCLUDE_ARGS[@]}"; then
		echo "ERROR: restic restore failed."
		RESTORE_FAILED='yes'
	else
		for p in "${RESTORE_PATHS[@]}"; do
			src="$STAGING$p"

			if [ ! -d "$src" ]; then
				echo "ERROR: '$p' is not contained in the snapshot."
				RESTORE_FAILED='yes'
				continue
			fi

			# the target was renamed earlier, so it must no longer exist
			if [ -e "$p" ]; then
				echo "ERROR: '$p' still exists - not overwriting it."
				RESTORE_FAILED='yes'
				continue
			fi

			if mv "$src" "$p"; then
				echo "Restored: $p"
			else
				echo "ERROR: could not move '$src' to '$p'."
				RESTORE_FAILED='yes'
			fi
		done
	fi
fi

# .sh files individually, so nothing else in COMPOSE_BASE is touched
if [ "$RESTORE_SH" = 'yes' ]; then
	SH_BACKUP_DIR="$COMPOSE_BASE/_sh-backup_${STAMP}"

	echo
	echo "Backing up existing .sh files to $SH_BACKUP_DIR ..."
	shopt -s nullglob
	EXISTING_SH=("$COMPOSE_BASE"/*.sh)
	shopt -u nullglob

	if [ "${#EXISTING_SH[@]}" -gt 0 ]; then
		if ! mkdir -p "$SH_BACKUP_DIR"; then
			abort "Could not create $SH_BACKUP_DIR."
		fi
		for f in "${EXISTING_SH[@]}"; do
			if mv "$f" "$SH_BACKUP_DIR/"; then
				echo "Moved: $f"
			else
				echo "WARNING: could not move $f."
				RESTORE_FAILED='yes'
			fi
		done
		RENAMED_DIRS+=("$SH_BACKUP_DIR")
	else
		echo "No existing .sh files found."
	fi

	if ! mkdir -p "$STAGING"; then
		abort "Could not create staging directory $STAGING."
	fi

	echo "Extracting .sh files to $STAGING ..."
	if ! run_restic restore "$SELECTED_SNAP" --target "$STAGING" --include "$COMPOSE_BASE/*.sh"; then
		echo "ERROR: restoring the .sh files failed."
		RESTORE_FAILED='yes'
	else
		shopt -s nullglob
		RESTORED_SH=("$STAGING$COMPOSE_BASE"/*.sh)
		shopt -u nullglob

		if [ "${#RESTORED_SH[@]}" -eq 0 ]; then
			echo "WARNING: no .sh files are contained in the snapshot."
		else
			for f in "${RESTORED_SH[@]}"; do
				if mv "$f" "$COMPOSE_BASE/"; then
					echo "Restored: $COMPOSE_BASE/$(basename "$f")"
				else
					echo "ERROR: could not move $f."
					RESTORE_FAILED='yes'
				fi
			done
		fi
	fi
fi

cleanup_staging
trap - EXIT

# ---------------------------------------------------------------------------
# Step 7: Result
# ---------------------------------------------------------------------------

echo
echo "==========================================================="
if [ "$RESTORE_FAILED" = 'yes' ]; then
	echo " Restore finished WITH ERRORS"
else
	echo " Restore completed"
fi
echo "==========================================================="
echo

if [ "${#RENAMED_DIRS[@]}" -gt 0 ]; then
	echo "Old data was renamed and NOT deleted:"
	for d in "${RENAMED_DIRS[@]}"; do
		echo "  $d"
	done
	echo
	echo "Please remove it manually once you've verified everything, e.g.:"
	for d in "${RENAMED_DIRS[@]}"; do
		echo "  rm -rf '$d'"
	done
	echo
fi

if [ "$RESTORE_MODE" = '1' ]; then
	COMPOSE_DIR="$COMPOSE_BASE/$PROJECT"

	if [ "$RESTORE_FAILED" = 'yes' ]; then
		echo "Because of the errors above, the service will NOT be started automatically."
		echo "After checking, start it manually with:"
		echo "  cd $COMPOSE_DIR && docker compose up -d"
		echo
	elif [ ! -d "$COMPOSE_DIR" ]; then
		echo "NOTE: $COMPOSE_DIR does not exist - the service cannot be started."
		echo
	elif ask_yes_no "Start service '$PROJECT' now?"; then
		echo
		echo "Starting '$PROJECT' ..."
		if (cd "$COMPOSE_DIR" && docker compose up -d); then
			sleep 3
			echo
			echo "Container status:"
			project_all_states "$PROJECT"
			echo
			if [ -z "$(project_running_ids "$PROJECT")" ]; then
				echo "WARNING: no container is running. Check the logs with:"
				echo "  cd $COMPOSE_DIR && docker compose logs"
				echo
			fi
		else
			echo "ERROR: start failed."
			echo "On a parsing error, check the compose file:"
			echo "  ls -la $COMPOSE_DIR"
			echo "  cat $COMPOSE_DIR/compose.yaml"
			echo "Check the logs with:"
			echo "  cd $COMPOSE_DIR && docker compose logs"
			echo
			RESTORE_FAILED='yes'
		fi
	else
		echo
		echo "Start the service later with:"
		echo "  cd $COMPOSE_DIR && docker compose up -d"
		echo
	fi
fi

if [ "$RESTORE_FAILED" = 'yes' ]; then
	exit 1
fi