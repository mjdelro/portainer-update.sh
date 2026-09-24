#!/usr/bin/env bash
set -Eeuo pipefail

# Installs a guarded, systemd-based updater for one Portainer CE container.

PORTAINER_NAME="portainer"
PORTAINER_VOLUME="portainer_data"
UPDATER="/usr/local/sbin/update-portainer"
SERVICE="/etc/systemd/system/portainer-update.service"
TIMER="/etc/systemd/system/portainer-update.timer"

BACKUP_DIR="/var/backups/portainer"
KEEP_BACKUPS=5

if [[ ${EUID} -ne 0 ]]; then
    printf 'Run this installer as root, for example: sudo %q\n' "$0" >&2
    exit 1
fi

for command in curl docker find flock grep install journalctl sort systemctl tar; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'ERROR: Required command %q was not found.\n' "$command" >&2
        exit 1
    fi
done

if ! docker inspect --type container "$PORTAINER_NAME" >/dev/null 2>&1; then
    printf "ERROR: Docker container '%s' does not exist.\n" "$PORTAINER_NAME" >&2
    exit 1
fi

if ! docker volume inspect "$PORTAINER_VOLUME" >/dev/null 2>&1; then
    printf "ERROR: Docker volume '%s' does not exist.\n" "$PORTAINER_VOLUME" >&2
    exit 1
fi

if [[ "$(docker inspect --format '{{.State.Running}}' "$PORTAINER_NAME")" != "true" ]]; then
    printf "ERROR: Docker container '%s' must be running before installation.\n" "$PORTAINER_NAME" >&2
    exit 1
fi

install -d -m 700 "$BACKUP_DIR"

cat >"$UPDATER" <<'UPDATER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

NAME="portainer"
IMAGE="portainer/portainer-ce:lts"
VOLUME="portainer_data"
BACKUP_DIR="/var/backups/portainer"
KEEP_BACKUPS=5
LOCK_FILE="/run/lock/portainer-update.lock"

umask 077

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

version_from_container() {
    docker exec "$NAME" /portainer --version 2>/dev/null \
        | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' \
        | head -n 1 || true
}

version_from_image() {
    docker run --rm "$1" --version 2>/dev/null \
        | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' \
        | head -n 1 || true
}

prune_backups() {
    local file

    log "Keeping the newest ${KEEP_BACKUPS} Portainer backups."
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        log "Removing old backup: $file"
        rm -f -- "$file"
    done < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f \
            -name 'portainer-data-*.tar.gz' -printf '%T@ %p\n' \
            | sort -nr \
            | tail -n +"$((KEEP_BACKUPS + 1))" \
            | cut -d' ' -f2-
    )
}

start_portainer() {
    local image="$1"

    docker run -d \
        --name "$NAME" \
        --restart=always \
        -p 127.0.0.1:9000:9000 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${VOLUME}:/data" \
        "$image"
}

wait_for_portainer() {
    local attempt

    for attempt in {1..30}; do
        if curl -fsS --connect-timeout 2 --max-time 5 \
            http://127.0.0.1:9000/api/status >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

restore_backup() {
    local backup="$1"

    log "Restoring Portainer data from $backup"
    if ! find "$VOLUME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; then
        log "CRITICAL: Could not clear the Portainer volume for restoration."
        return 1
    fi

    if ! tar -C "$VOLUME_DIR" -xzf "$backup"; then
        log "CRITICAL: Could not extract the Portainer backup."
        return 1
    fi
}

rollback() {
    local backup="$1"
    local old_image_id="$2"

    log "Beginning automatic rollback."
    docker logs "$NAME" --tail 100 2>&1 || true
    docker rm -f "$NAME" >/dev/null 2>&1 || true

    if ! restore_backup "$backup"; then
        log "CRITICAL: Could not restore Portainer data. Backup retained at: $backup"
        return 2
    fi

    log "Restarting the previous Portainer image."
    if ! start_portainer "$old_image_id" >/dev/null; then
        log "CRITICAL: Could not recreate the rollback container."
        log "Backup retained at: $backup"
        return 2
    fi

    if wait_for_portainer; then
        log "Rollback successful. Backup retained at: $backup"
        return 0
    fi

    log "CRITICAL: The rollback container failed its health check."
    log "Backup retained at: $backup"
    return 2
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another Portainer update check is already running; exiting."
    exit 0
fi

install -d -m 700 "$BACKUP_DIR"

if ! docker inspect --type container "$NAME" >/dev/null 2>&1; then
    log "ERROR: Portainer container '$NAME' does not exist."
    exit 1
fi

if [[ "$(docker inspect --format '{{.State.Running}}' "$NAME")" != "true" ]]; then
    log "ERROR: Portainer container '$NAME' is not running."
    exit 1
fi

if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
    log "ERROR: Portainer volume '$VOLUME' does not exist."
    exit 1
fi

VOLUME_DIR="$(docker volume inspect --format '{{.Mountpoint}}' "$VOLUME")"
if [[ -z "$VOLUME_DIR" || ! -d "$VOLUME_DIR" ]]; then
    log "ERROR: Could not resolve the Portainer volume mountpoint."
    exit 1
fi

OLD_IMAGE_ID="$(docker inspect --format '{{.Image}}' "$NAME")"
CURRENT_VERSION="$(version_from_container)"
log "Current Portainer version: ${CURRENT_VERSION:-unknown}"

log "Checking $IMAGE for an updated image."
docker pull "$IMAGE"
NEW_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$IMAGE")"

if [[ "$OLD_IMAGE_ID" == "$NEW_IMAGE_ID" ]]; then
    log "Portainer is already current."
    prune_backups
    exit 0
fi

TARGET_VERSION="$(version_from_image "$IMAGE")"
log "Available LTS version: ${TARGET_VERSION:-unknown}"

if [[ -z "$CURRENT_VERSION" || -z "$TARGET_VERSION" ]]; then
    log "ERROR: Could not verify both versions; refusing to replace Portainer."
    exit 1
fi

OLDEST_VERSION="$(printf '%s\n%s\n' "$CURRENT_VERSION" "$TARGET_VERSION" | sort -V | head -n 1)"
if [[ "$OLDEST_VERSION" == "$TARGET_VERSION" && "$CURRENT_VERSION" != "$TARGET_VERSION" ]]; then
    log "REFUSING UPDATE: installed version $CURRENT_VERSION is newer than LTS $TARGET_VERSION."
    exit 0
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP="${BACKUP_DIR}/portainer-data-${TIMESTAMP}.tar.gz"

log "New Portainer image detected. Stopping Portainer."
docker stop "$NAME" >/dev/null

log "Creating backup: $BACKUP"
if ! tar -C "$VOLUME_DIR" -czf "$BACKUP" .; then
    log "ERROR: Backup creation failed; restarting the existing container."
    rm -f -- "$BACKUP"
    docker start "$NAME" >/dev/null || true
    exit 1
fi

if ! tar -tzf "$BACKUP" >/dev/null; then
    log "ERROR: Backup verification failed; restarting the existing container."
    rm -f -- "$BACKUP"
    docker start "$NAME" >/dev/null || true
    exit 1
fi
log "Backup verified."

if ! docker rm "$NAME" >/dev/null; then
    log "ERROR: Could not remove the stopped Portainer container; restarting it."
    docker start "$NAME" >/dev/null || true
    exit 1
fi
log "Starting updated Portainer."

if ! start_portainer "$IMAGE" >/dev/null; then
    log "ERROR: The updated Portainer container could not be created."
    rollback "$BACKUP" "$OLD_IMAGE_ID" || exit $?
    exit 1
fi

if wait_for_portainer; then
    RUNNING_VERSION="$(version_from_container)"
    log "Portainer update successful. Running version: ${RUNNING_VERSION:-unknown}"
    log "Backup: $BACKUP"
    prune_backups
    exit 0
fi

log "ERROR: Updated Portainer did not become healthy."
rollback "$BACKUP" "$OLD_IMAGE_ID" || exit $?
exit 1
UPDATER_EOF

chmod 750 "$UPDATER"

cat >"$SERVICE" <<'SERVICE_EOF'
[Unit]
Description=Update Portainer CE LTS
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service
ConditionPathExists=/var/run/docker.sock

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-portainer
TimeoutStartSec=10min
SERVICE_EOF

cat >"$TIMER" <<'TIMER_EOF'
[Unit]
Description=Daily Portainer CE LTS update check

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
TIMER_EOF

systemctl daemon-reload
systemctl enable --now portainer-update.timer

printf '\nPortainer automatic updates are installed.\n'
printf 'Updater: %s\nBackups: %s (newest %s retained)\n\n' \
    "$UPDATER" "$BACKUP_DIR" "$KEEP_BACKUPS"
printf 'Running the initial update check now.\n'
systemctl start portainer-update.service

printf '\nCurrent Portainer version:\n'
docker exec "$PORTAINER_NAME" /portainer --version || true
printf '\nTimer schedule:\n'
systemctl list-timers portainer-update.timer --no-pager
printf '\nRecent updater log:\n'
journalctl -u portainer-update.service -n 20 --no-pager
