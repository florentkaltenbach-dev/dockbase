#!/bin/bash
# Dockbase Backup Script
# Mode-aware: reads DEPLOY_MODE from config.env, only backs up active stacks.
#
# Tags: shop-db, shop-files, shop-matomo, web-files, web-matomo, mailcow
# Always runs as `deploy` user.

set -Eeuo pipefail

# Enforce consistent user context
if [ "$(id -un)" != "deploy" ]; then
    exec sudo -u deploy -H bash "$0" "$@"
fi

cd /opt/dockbase

LOG_FILE="logs/backup.log"
LOCK_FILE="/var/lock/dockbase-backup.lock"
TMP_BACKUP="/tmp/dockbase-backup-$$"

log() {
    echo "$(date '+%a %b %d %T %Z %Y'): $*" >> "$LOG_FILE"
}

load_env_var() {
    local key="$1"
    local optional="${2:-required}"
    local value
    value="$(grep -m1 "^${key}=" config.env 2>/dev/null | cut -d= -f2- || true)"
    if [ -z "$value" ]; then
        if [ "$optional" = "optional" ]; then
            export "${key}="
            return 0
        fi
        log "ERROR - Missing ${key} in /opt/dockbase/config.env"
        exit 1
    fi
    export "${key}=${value}"
}

mode_includes() {
    case "$DEPLOY_MODE" in
        full) return 0 ;;
        "$1") return 0 ;;
        *) return 1 ;;
    esac
}

# Healthchecks.io heartbeat (no-op if URL is empty/missing).
# /start at begin, bare URL on success, /fail with log-tail body on error.
hc_ping() {
    local suffix="${1:-}"
    [ -z "${HEALTHCHECKS_BACKUP_URL:-}" ] && return 0
    local url="${HEALTHCHECKS_BACKUP_URL}${suffix}"
    if [ "$suffix" = "/fail" ] && [ -f "$LOG_FILE" ]; then
        tail -c 8000 "$LOG_FILE" 2>/dev/null \
            | curl -fsS -m 10 --retry 3 --data-binary @- "$url" >/dev/null 2>&1 || true
    else
        curl -fsS -m 10 --retry 3 -X POST "$url" >/dev/null 2>&1 || true
    fi
}

mkdir -p logs

# Prevent overlapping runs
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Another backup run is active, skipping."
    exit 0
fi

load_env_var MYSQL_DATABASE
load_env_var MYSQL_ROOT_PASSWORD
load_env_var RESTIC_REPOSITORY
load_env_var RESTIC_PASSWORD
load_env_var DEPLOY_MODE
load_env_var HEALTHCHECKS_BACKUP_URL optional

# Tracks completion state for the EXIT trap:
#   ""     → signal-kill or early exit (no ERR, no normal end) → ping /fail
#   "fail" → ERR fired (already pinged /fail with body)        → no extra ping
#   "1"    → normal success                                    → ping bare URL
BACKUP_OK=

trap 'rc=$?; rm -rf "$TMP_BACKUP"; log "ERROR - Backup failed (line ${LINENO}, exit ${rc})"; BACKUP_OK=fail; hc_ping /fail; exit $rc' ERR
trap '
  rm -rf "$TMP_BACKUP"
  case "${BACKUP_OK:-}" in
      1)    hc_ping "" ;;
      fail) ;;
      *)    hc_ping /fail ;;
  esac
' EXIT

hc_ping /start

# ── Healthcheck Gate ──────────────────────────────────────
log "Waiting for healthy containers..."
TIMEOUT=300
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    UNHEALTHY=$(docker compose ps --format json 2>/dev/null | \
        jq -r 'select(.Health != "healthy" and .Health != "" and .Health != null) | .Name' 2>/dev/null | wc -l || echo "0")
    if [ "$UNHEALTHY" -eq 0 ]; then
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log "ERROR - Containers not healthy after ${TIMEOUT}s, aborting."
    exit 1
fi

log "Starting backup (mode: ${DEPLOY_MODE})..."

# Clean stale remote locks
restic unlock >> "$LOG_FILE" 2>&1 || true

# ── Infra config (always) ────────────────────────────────
# Host-local-only files needed to restore the stack. Tiny snapshot.
# Includes the load-bearing secrets for backup recovery itself
# (RESTIC_PASSWORD, storagebox SSH key); those values MUST also live in
# an off-host password manager — otherwise restoring from this snapshot
# requires data only this snapshot contains.
log "=== Infra config ==="
mkdir -p "${TMP_BACKUP}/infra"
cp /opt/dockbase/config.env "${TMP_BACKUP}/infra/"
cp /opt/dockbase/config/backup/backup_key "${TMP_BACKUP}/infra/" 2>> "$LOG_FILE" || true
if [ -r /opt/mailcow/mailcow.conf ]; then
    cp /opt/mailcow/mailcow.conf "${TMP_BACKUP}/infra/" 2>> "$LOG_FILE" || true
fi
crontab -l > "${TMP_BACKUP}/infra/deploy.crontab" 2>> "$LOG_FILE" || true
restic --retry-lock 5m backup "${TMP_BACKUP}/infra/" --tag infra >> "$LOG_FILE" 2>&1

# ── Shop backup (if mode is full or shop) ────────────────
if mode_includes shop; then
    log "=== Shop backup ==="

    # shop-db: SQL dump of the shop database
    mkdir -p "${TMP_BACKUP}/shop-db"
    log "Dumping shop database..."
    docker compose exec -T mariadb mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" \
        --single-transaction "$MYSQL_DATABASE" > "${TMP_BACKUP}/shop-db/${MYSQL_DATABASE}.sql" 2>> "$LOG_FILE"
    restic --retry-lock 5m backup "${TMP_BACKUP}/shop-db/" --tag shop-db >> "$LOG_FILE" 2>&1

    # shop-files: uploads + languages
    log "Backing up shop files (uploads + languages)..."
    mkdir -p "${TMP_BACKUP}/shop-files/uploads" "${TMP_BACKUP}/shop-files/languages"
    docker cp dockbase_frankenphp:/app/web/app/uploads/. "${TMP_BACKUP}/shop-files/uploads/" 2>> "$LOG_FILE"
    docker cp dockbase_frankenphp:/app/web/app/languages/. "${TMP_BACKUP}/shop-files/languages/" 2>> "$LOG_FILE" || true
    restic --retry-lock 5m backup "${TMP_BACKUP}/shop-files/" --tag shop-files >> "$LOG_FILE" 2>&1

    # shop-matomo: matomo_shop SQL + volume data
    log "Backing up shop Matomo..."
    mkdir -p "${TMP_BACKUP}/shop-matomo/data"
    docker compose exec -T mariadb mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" \
        --single-transaction matomo_shop > "${TMP_BACKUP}/shop-matomo/matomo_shop.sql" 2>> "$LOG_FILE"
    docker cp dockbase_matomo_shop:/var/www/html/. "${TMP_BACKUP}/shop-matomo/data/" 2>> "$LOG_FILE"
    restic --retry-lock 5m backup "${TMP_BACKUP}/shop-matomo/" --tag shop-matomo >> "$LOG_FILE" 2>&1
fi

# ── Website backup (if mode is full or web) ──────────────
if mode_includes web; then
    log "=== Website backup ==="

    # web-files: website content
    if [ -d "/opt/dockbase/website/public" ]; then
        log "Backing up website files..."
        restic --retry-lock 5m backup /opt/dockbase/website/public/ --tag web-files >> "$LOG_FILE" 2>&1
    fi

    # web-matomo: matomo_web SQL + volume data
    log "Backing up web Matomo..."
    mkdir -p "${TMP_BACKUP}/web-matomo/data"
    docker compose exec -T mariadb mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" \
        --single-transaction matomo_web > "${TMP_BACKUP}/web-matomo/matomo_web.sql" 2>> "$LOG_FILE" || true
    docker cp dockbase_matomo_web:/var/www/html/. "${TMP_BACKUP}/web-matomo/data/" 2>> "$LOG_FILE" || true
    if [ -f "${TMP_BACKUP}/web-matomo/matomo_web.sql" ]; then
        restic --retry-lock 5m backup "${TMP_BACKUP}/web-matomo/" --tag web-matomo >> "$LOG_FILE" 2>&1
    fi
fi

# ── Mailcow backup (if mode is full or mail) ─────────────
if mode_includes mail; then
    log "=== Mailcow backup ==="
    MAILCOW_DIR="/opt/mailcow"
    MAILCOW_BACKUP_DIR="/opt/mailcow-backup"

    if [ -d "$MAILCOW_DIR" ]; then
        # Precondition: target dir must exist and be writable by deploy.
        # setup-mailcow.sh creates it (deploy:deploy 0755). Fail fast otherwise
        # so the operator notices instead of silently snapshotting nothing.
        if [ ! -d "$MAILCOW_BACKUP_DIR" ] || [ ! -w "$MAILCOW_BACKUP_DIR" ]; then
            log "ERROR - ${MAILCOW_BACKUP_DIR} missing or not writable by $(id -un); rerun infra/setup-mailcow.sh"
            exit 1
        fi

        log "Running Mailcow backup via helper-scripts..."
        cd "$MAILCOW_DIR"
        # No `mailcowdockerized_backup_1` service exists; call the helper script
        # directly. Drop --delete-days 0 (it deleted prior on-disk backups
        # before restic could snapshot them).
        MAILCOW_BACKUP_LOCATION="$MAILCOW_BACKUP_DIR" \
            bash "${MAILCOW_DIR}/helper-scripts/backup_and_restore.sh" backup all \
            >> "$LOG_FILE" 2>&1
        cd /opt/dockbase

        log "Snapshotting Mailcow backup to Restic..."
        restic --retry-lock 5m backup "$MAILCOW_BACKUP_DIR/" --tag mailcow >> "$LOG_FILE" 2>&1
    else
        log "Mailcow not installed at ${MAILCOW_DIR}, skipping."
    fi
fi

# ── Retention ─────────────────────────────────────────────
log "Applying retention policy..."
restic unlock >> "$LOG_FILE" 2>&1 || true
restic --retry-lock 5m forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >> "$LOG_FILE" 2>&1 || \
    log "Warning - Retention/prune failed; snapshots were still created."

log "Backup completed successfully (mode: ${DEPLOY_MODE})"
echo "---" >> "$LOG_FILE"
BACKUP_OK=1
# EXIT trap will emit the success heartbeat (bare URL).
