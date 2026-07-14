#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

ENV_FILE="${SCRIPT_DIR}/backup.env"
COMPOSE_FILE="${SCRIPT_DIR}/compose.yaml"
LOCK_FILE="${SCRIPT_DIR}/var/lock/restore.lock"

MODE=""
SNAPSHOT="latest"

BACKUP_DIR=""
RESTORE_COMPLETED=0
CONTAINER_WAS_RUNNING=0

log() {
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat <<EOF
Usage:
  sudo $0 bootstrap [snapshot]
  sudo $0 restore [snapshot]

Modes:
  bootstrap   Create a new Nextcloud instance from a backup.
              The target directory must not already contain data.

  restore     Replace an existing Nextcloud instance from a backup.
              The existing directory is preserved as a timestamped copy.

Arguments:
  snapshot    Restic snapshot ID. Defaults to "latest".

Examples:
  sudo $0 bootstrap
  sudo $0 bootstrap b9c587b8
  sudo $0 restore
  sudo $0 restore b9c587b8
EOF
}

load_environment() {
    [[ -r "$ENV_FILE" ]] ||
        fail "Environment file is not readable: $ENV_FILE"

    set -a

    # shellcheck source=/dev/null
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
        [[ -n "${!variable:-}" ]] ||
            fail "Required variable is missing or empty: $variable"
    done

    command -v restic >/dev/null 2>&1 ||
        fail "Restic is not installed or is not available in PATH."

    command -v docker >/dev/null 2>&1 ||
        fail "Docker is not installed or is not available in PATH."

    docker compose version >/dev/null 2>&1 ||
        fail "Docker Compose is not available."

    [[ -f "$COMPOSE_FILE" ]] ||
        fail "Docker Compose file was not found: $COMPOSE_FILE"

    [[ "$NEXTCLOUD_BACKUP_PATH" == /* ]] ||
        fail "NEXTCLOUD_BACKUP_PATH must be an absolute path."

    [[ "$NEXTCLOUD_BACKUP_PATH" != "/" ]] ||
        fail "NEXTCLOUD_BACKUP_PATH cannot be /."
}

parse_arguments() {
    if [[ $# -lt 1 || $# -gt 2 ]]; then
        usage
        exit 1
    fi

    MODE="$1"
    SNAPSHOT="${2:-latest}"

    case "$MODE" in
        bootstrap|restore)
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            fail "Unknown mode: $MODE"
            ;;
    esac
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"

    exec 9>"$LOCK_FILE"

    flock -n 9 ||
        fail "Another restore or bootstrap operation is already running."
}

validate_snapshot() {
    log "Checking Restic repository and snapshot: $SNAPSHOT"

    if ! restic ls "$SNAPSHOT" >/dev/null; then
        fail "Snapshot does not exist or the repository cannot be accessed: $SNAPSHOT"
    fi
}

container_exists() {
    docker inspect "$NEXTCLOUD_CONTAINER" >/dev/null 2>&1
}

container_is_running() {
    [[ "$(
        docker inspect \
            --format '{{.State.Running}}' \
            "$NEXTCLOUD_CONTAINER" 2>/dev/null
    )" == "true" ]]
}

stop_existing_instance() {
    if ! container_exists; then
        log "Nextcloud container does not currently exist."
        return
    fi

    if container_is_running; then
        CONTAINER_WAS_RUNNING=1

        log "Stopping Nextcloud container..."
        docker stop "$NEXTCLOUD_CONTAINER" >/dev/null
    else
        log "Nextcloud container is already stopped."
    fi
}

directory_has_contents() {
    local directory="$1"

    [[ -d "$directory" ]] &&
        [[ -n "$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

prepare_bootstrap() {
    if [[ -e "$NEXTCLOUD_BACKUP_PATH" ]]; then
        if [[ ! -d "$NEXTCLOUD_BACKUP_PATH" ]]; then
            fail "Target exists but is not a directory: $NEXTCLOUD_BACKUP_PATH"
        fi

        if directory_has_contents "$NEXTCLOUD_BACKUP_PATH"; then
            fail "Bootstrap target is not empty: $NEXTCLOUD_BACKUP_PATH"
        fi

        rmdir "$NEXTCLOUD_BACKUP_PATH"
    fi

    log "Preparing a new Nextcloud instance from snapshot $SNAPSHOT"
}

prepare_restore() {
    local timestamp

    timestamp="$(date '+%Y%m%d-%H%M%S')"

    if [[ -e "$NEXTCLOUD_BACKUP_PATH" ]]; then
        BACKUP_DIR="${NEXTCLOUD_BACKUP_PATH}.before-restore.${timestamp}"

        log "Preserving current installation at: $BACKUP_DIR"
        mv "$NEXTCLOUD_BACKUP_PATH" "$BACKUP_DIR"
    else
        log "Current Nextcloud directory does not exist; continuing as a clean restore."
    fi
}

prepare_target() {
    case "$MODE" in
        bootstrap)
            prepare_bootstrap
            ;;
        restore)
            prepare_restore
            ;;
    esac

    mkdir -p "$(dirname "$NEXTCLOUD_BACKUP_PATH")"
}

restore_snapshot() {
    log "Restoring snapshot $SNAPSHOT..."

    restic restore "$SNAPSHOT" \
        --target / \
        --include "$NEXTCLOUD_BACKUP_PATH"

    [[ -d "$NEXTCLOUD_BACKUP_PATH" ]] ||
        fail "Restore finished, but the expected directory is missing: $NEXTCLOUD_BACKUP_PATH"

    [[ -f "$NEXTCLOUD_BACKUP_PATH/config/config.php" ]] ||
        fail "Restored Nextcloud config.php was not found."

    RESTORE_COMPLETED=1

    log "Snapshot restored successfully."
}

start_instance() {
    log "Starting Nextcloud with Docker Compose..."

    docker compose \
        --project-directory "$SCRIPT_DIR" \
        -f "$COMPOSE_FILE" \
        up -d

    log "Waiting for the Nextcloud container to become available..."

    local attempts=30

    while (( attempts > 0 )); do
        if container_exists && container_is_running; then
            break
        fi

        sleep 1
        ((attempts--))
    done

    container_exists ||
        fail "Nextcloud container was not created."

    container_is_running ||
        fail "Nextcloud container did not start successfully."
}

disable_maintenance_mode() {
    log "Disabling Nextcloud maintenance mode if enabled..."

    docker exec \
        -u www-data \
        "$NEXTCLOUD_CONTAINER" \
        php /var/www/html/occ maintenance:mode --off \
        >/dev/null 2>&1 || {
            log "WARNING: Could not disable maintenance mode automatically."
            log "Run manually:"
            log "docker exec -u www-data $NEXTCLOUD_CONTAINER php /var/www/html/occ maintenance:mode --off"
        }
}

rollback_on_failure() {
    local exit_code=$?

    trap - EXIT INT TERM HUP

    if [[ "$exit_code" -eq 0 ]]; then
        return
    fi

    log "Restore operation failed."

    if container_exists && container_is_running; then
        log "Stopping partially restored Nextcloud container..."
        docker stop "$NEXTCLOUD_CONTAINER" >/dev/null 2>&1 || true
    fi

    if [[ "$RESTORE_COMPLETED" -eq 0 ]] &&
       [[ -n "$BACKUP_DIR" ]] &&
       [[ -e "$BACKUP_DIR" ]]; then

        if [[ -e "$NEXTCLOUD_BACKUP_PATH" ]]; then
            log "Removing incomplete restored directory..."
            rm -rf -- "$NEXTCLOUD_BACKUP_PATH"
        fi

        log "Restoring the previous installation..."
        mv "$BACKUP_DIR" "$NEXTCLOUD_BACKUP_PATH"

        if [[ "$CONTAINER_WAS_RUNNING" -eq 1 ]]; then
            log "Restarting the previous Nextcloud instance..."

            docker compose \
                --project-directory "$SCRIPT_DIR" \
                -f "$COMPOSE_FILE" \
                up -d || true
        fi
    fi

    exit "$exit_code"
}

main() {
    [[ "$EUID" -eq 0 ]] ||
        fail "Run this script as root."

    parse_arguments "$@"
    load_environment
    validate_environment
    acquire_lock

    trap rollback_on_failure EXIT INT TERM HUP

    validate_snapshot
    stop_existing_instance
    prepare_target
    restore_snapshot
    start_instance
    disable_maintenance_mode

    trap - EXIT INT TERM HUP

    log "Operation completed successfully."
    log "Mode: $MODE"
    log "Snapshot: $SNAPSHOT"

    if [[ -n "$BACKUP_DIR" ]]; then
        log "Previous installation preserved at: $BACKUP_DIR"
    fi
}

main "$@"
