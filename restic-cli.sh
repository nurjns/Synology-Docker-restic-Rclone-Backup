#!/bin/bash
#
# restic-cli.sh - ad-hoc restic commands with the same settings as backup.sh
# Version 1.0.0 - 2026-08-31
#
# Example: sudo ./restic-cli.sh snapshots
# Example: sudo ./restic-cli.sh restore latest --target /tmp/restore-test --tag <projectname>

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

"$RESTIC_BIN" "${RESTIC_OPTS[@]}" "$@"