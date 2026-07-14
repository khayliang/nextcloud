#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

ENV_FILE="${SCRIPT_DIR}/backup.env"
LOCK_FILE="${SCRIPT_DIR}/var/lock/backup.lock"

MAINTENANCE_ENABLED=0

log() {
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

load_environment() {
    [[ -f "$ENV_FILE" ]] ||
        fail "Environment file not found: $ENV_FILE"

    set -a

    source "$ENV_FILE"

    set +a
}

validate_environment() {
    local required_variables=(
        RESTIC_REPOSITORY
        RESTIC_PASSWORD
        AWS_ACCESS_KEY_ID
        AWS_SECRET_ACCESS_KEY
        NEXTCLOUD_CONTAINER
        NEXTCLOUD_BACKUP_PATH
    )

    local variable

    for variable in "${required_variables[@]}"; do
        if [[ -z "${!variable:-}" ]]; then
            fail "Required variable is missing or empty: $variable"
        fi
    done

    [[ -n "$RESTIC_PASSWORD" ]] ||
        fail "Restic password is not available: $RESTIC_PASSWORD"

    [[ -d "$NEXTCLOUD_BACKUP_PATH" ]] ||
        fail "Nextcloud backup path does not exist: $NEXTCLOUD_BACKUP_PATH"

    command -v docker >/dev/null 2>&1 ||
        fail "Docker is not installed or is not available in PATH."

    docker inspect "$NEXTCLOUD_CONTAINER" >/dev/null 2>&1 ||
        fail "Nextcloud container does not exist: $NEXTCLOUD_CONTAINER"

    local container_running

    container_running="$(
        docker inspect \
            --format '{{.State.Running}}' \
            "$NEXTCLOUD_CONTAINER"
    )"

    [[ "$container_running" == "true" ]] ||
        fail "Nextcloud container is not running: $NEXTCLOUD_CONTAINER"
}

enable_maintenance_mode() {
    log "Enabling Nextcloud maintenance mode..."

    docker exec \
        -u www-data \
        "$NEXTCLOUD_CONTAINER" \
        php /var/www/html/occ maintenance:mode --on

    MAINTENANCE_ENABLED=1
}

disable_maintenance_mode() {
    if [[ "$MAINTENANCE_ENABLED" -ne 1 ]]; then
        return
    fi

    log "Disabling Nextcloud maintenance mode..."

    docker exec \
        -u www-data \
        "$NEXTCLOUD_CONTAINER" \
        php /var/www/html/occ maintenance:mode --off

    MAINTENANCE_ENABLED=0
}

cleanup() {
    local exit_code=$?

    trap - EXIT INT TERM HUP

    if [[ "$MAINTENANCE_ENABLED" -eq 1 ]]; then
        if ! disable_maintenance_mode; then
            log "ERROR: Failed to disable Nextcloud maintenance mode."
            exit_code=1
        fi
    fi

    if [[ "$exit_code" -eq 0 ]]; then
        log "Backup completed successfully."
    else
        log "Backup failed with exit code $exit_code."
    fi

    exit "$exit_code"
}

run_backup() {
    log "Backing up $NEXTCLOUD_BACKUP_PATH..."

    if ! restic snapshots >/dev/null 2>&1; then
        log "Repository not initialized. Initializing..."
        restic init
    fi

    restic backup \
        --host "$(hostname)" \
        --tag nextcloud \
        "$NEXTCLOUD_BACKUP_PATH"

    log "Restic backup completed."
}

main() {
    load_environment
    validate_environment

    mkdir -p "$(dirname "$LOCK_FILE")"

    exec 9>"$LOCK_FILE"

    if ! flock -n 9; then
        fail "Another Nextcloud backup is already running."
    fi

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    enable_maintenance_mode
    run_backup
    disable_maintenance_mode

    restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --prune
}

main "$@"
