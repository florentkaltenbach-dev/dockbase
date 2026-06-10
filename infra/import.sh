#!/bin/bash
# Dockbase Data Import
# Mode-aware: restores only data relevant to DEPLOY_MODE.
# Supports both new-format tags (shop-db, etc.) and legacy tags (db, uploads, etc.).
# Run as root after the stack is running.
# Usage: sudo bash import.sh [--skip-restore]

set -Eeuo pipefail

SKIP_RESTORE=false
for arg in "$@"; do
    case "$arg" in
        --skip-restore) SKIP_RESTORE=true ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_config

CONTAINER="dockbase_frankenphp"
DB_CONTAINER="dockbase_mariadb"

mode_includes() {
    case "$DEPLOY_MODE" in
        full) return 0 ;;
        "$1") return 0 ;;
        *) return 1 ;;
    esac
}

# Helper: create temp dir owned by deploy user
make_tmp() {
    sudo -u deploy mktemp -d
}

# Helper: run restic as deploy user
run_restic() {
    sudo -u deploy \
        RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
        RESTIC_PASSWORD="$RESTIC_PASSWORD" \
        restic "$@"
}

# Helper: check if a restic tag has any snapshots
tag_exists() {
    local count
    count=$(run_restic snapshots --tag "$1" --json 2>/dev/null | jq length 2>/dev/null || echo "0")
    [ "$count" -gt 0 ]
}

# ── Ensure StorageBox SSH config exists ───────────────────
DEPLOY_SSH_DIR="/home/deploy/.ssh"
BACKUP_KEY="$INSTALL_DIR/config/backup/backup_key"
if [ -n "${STORAGEBOX_HOST:-}" ] && ! grep -q "Host storagebox" "$DEPLOY_SSH_DIR/config" 2>/dev/null; then
    log_info "StorageBox SSH config missing — creating it..."
    mkdir -p "$DEPLOY_SSH_DIR"
    cat >> "$DEPLOY_SSH_DIR/config" <<SSHCFG

Host storagebox
    HostName ${STORAGEBOX_HOST}
    User ${STORAGEBOX_USER}
    Port ${STORAGEBOX_PORT:-23}
    IdentityFile ${BACKUP_KEY}
    StrictHostKeyChecking accept-new
SSHCFG
    chmod 0600 "$DEPLOY_SSH_DIR/config"
    chown -R deploy:deploy "$DEPLOY_SSH_DIR"
    sudo -u deploy ssh-keyscan -p "${STORAGEBOX_PORT:-23}" "$STORAGEBOX_HOST" >> "$DEPLOY_SSH_DIR/known_hosts" 2>/dev/null || true
fi

log_info "=== Dockbase Data Import (mode: ${DEPLOY_MODE}) ==="

# ── Healthcheck Gate ──────────────────────────────────────
wait_healthy "${INSTALL_DIR}" 300

# ── Detect snapshot format ───────────────────────────────
# If both new-format and legacy tags exist, pick whichever has the newer snapshot.
USE_LEGACY=false
HAS_NEW=$(tag_exists "shop-db" && echo true || echo false)
HAS_LEGACY=$(tag_exists "db" && echo true || echo false)

if [ "$HAS_NEW" = true ] && [ "$HAS_LEGACY" = true ]; then
    NEW_TS=$(run_restic snapshots --tag shop-db --json 2>/dev/null | jq -r '.[-1].time // empty' 2>/dev/null || echo "")
    LEGACY_TS=$(run_restic snapshots --tag db --json 2>/dev/null | jq -r '.[-1].time // empty' 2>/dev/null || echo "")
    if [[ "$LEGACY_TS" > "$NEW_TS" ]]; then
        USE_LEGACY=true
        log_info "Both tag formats exist. Legacy 'db' is newer — using legacy tags."
    else
        log_info "Both tag formats exist. New-format 'shop-db' is newer — using new-format tags."
    fi
elif [ "$HAS_NEW" = true ]; then
    log_info "Using new-format backup tags."
elif [ "$HAS_LEGACY" = true ]; then
    USE_LEGACY=true
    log_info "New-format tags not found. Using legacy tags for migration restore."
else
    log_info "No backup snapshots found at all."
fi

if [ "$SKIP_RESTORE" = true ]; then
    log_info "Skipping data restore (--skip-restore)."
else
    # ══════════════════════════════════════════════════════
    #  Shop restore (if mode is full or shop)
    # ══════════════════════════════════════════════════════
    if mode_includes shop; then
        log_info "=== Restoring shop data ==="

        if [ "$USE_LEGACY" = true ]; then
            # ── Legacy restore path ──────────────────────
            log_info "Restoring uploads (legacy tag: uploads)..."
            RESTORE_TMP=$(make_tmp)
            run_restic --retry-lock 5m restore latest --tag uploads --target "$RESTORE_TMP"
            if [ -d "$RESTORE_TMP/backups/uploads" ]; then
                rsync -a --delete "$RESTORE_TMP/backups/uploads/" "$INSTALL_DIR/web/app/uploads/"
                log_info "Uploads restored."
            fi

            log_info "Restoring languages (legacy tag: languages)..."
            LANG_TMP=$(make_tmp)
            run_restic --retry-lock 5m restore latest --tag languages --target "$LANG_TMP" 2>/dev/null || true
            if [ -d "$LANG_TMP/backups/languages" ]; then
                rsync -a --delete "$LANG_TMP/backups/languages/" "$INSTALL_DIR/web/app/languages/"
                log_info "Languages restored."
            fi

            log_info "Restoring database (legacy tag: db)..."
            DB_TMP=$(make_tmp)
            run_restic --retry-lock 5m restore latest --tag db --target "$DB_TMP"
            if [ -f "$DB_TMP/backups/db/${MYSQL_DATABASE}.sql" ]; then
                docker exec -i "$DB_CONTAINER" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" \
                    < "$DB_TMP/backups/db/${MYSQL_DATABASE}.sql"
                log_info "WordPress database imported."
            fi
            # Legacy matomo dump goes into matomo_shop
            if [ -f "$DB_TMP/backups/db/matomo.sql" ]; then
                docker exec -i "$DB_CONTAINER" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" matomo_shop \
                    < "$DB_TMP/backups/db/matomo.sql"
                log_info "Matomo database imported (legacy matomo -> matomo_shop)."
            fi

            log_info "Restoring Matomo data (legacy tag: matomo)..."
            MATOMO_TMP=$(make_tmp)
            run_restic --retry-lock 5m restore latest --tag matomo --target "$MATOMO_TMP" 2>/dev/null || true
            if [ -d "$MATOMO_TMP/backups/matomo" ]; then
                docker cp "$MATOMO_TMP/backups/matomo/." dockbase_matomo_shop:/var/www/html/
                docker exec dockbase_matomo_shop chown -R www-data:www-data /var/www/html
                log_info "Matomo data volume restored."
            fi

            rm -rf "${RESTORE_TMP:-}" "${LANG_TMP:-}" "${DB_TMP:-}" "${MATOMO_TMP:-}"
        else
            # ── New-format restore path ──────────────────
            log_info "Restoring shop-db..."
            DB_TMP=$(make_tmp)
            run_restic --retry-lock 5m restore latest --tag shop-db --target "$DB_TMP"
            SHOP_SQL=$(find "$DB_TMP" -name "${MYSQL_DATABASE}.sql" | head -1)
            if [ -z "$SHOP_SQL" ]; then
                log_error "shop-db snapshot restored but ${MYSQL_DATABASE}.sql not found in ${DB_TMP}"
                log_error "Contents: $(ls -la "$DB_TMP" 2>/dev/null || true)"
                exit 1
            fi
            docker exec -i "$DB_CONTAINER" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" < "$SHOP_SQL"
            log_info "WordPress database imported."

            log_info "Restoring shop-files..."
            FILES_TMP=$(make_tmp)
            run_restic --retry-lock 5m restore latest --tag shop-files --target "$FILES_TMP"
            UPLOADS_DIR=$(find "$FILES_TMP" -type d -name "uploads" | head -1)
            LANGS_DIR=$(find "$FILES_TMP" -type d -name "languages" | head -1)
            [ -n "$UPLOADS_DIR" ] && rsync -a --delete "$UPLOADS_DIR/" "$INSTALL_DIR/web/app/uploads/"
            [ -n "$LANGS_DIR" ] && rsync -a --delete "$LANGS_DIR/" "$INSTALL_DIR/web/app/languages/"
            log_info "Shop files restored."

            if tag_exists "shop-matomo"; then
                log_info "Restoring shop-matomo..."
                SM_TMP=$(make_tmp)
                run_restic --retry-lock 5m restore latest --tag shop-matomo --target "$SM_TMP"
                SM_SQL=$(find "$SM_TMP" -name "matomo_shop.sql" | head -1)
                [ -n "$SM_SQL" ] && docker exec -i "$DB_CONTAINER" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" matomo_shop < "$SM_SQL"
                SM_DATA=$(find "$SM_TMP" -type d -name "data" | head -1)
                if [ -n "$SM_DATA" ]; then
                    docker cp "$SM_DATA/." dockbase_matomo_shop:/var/www/html/
                    docker exec dockbase_matomo_shop chown -R www-data:www-data /var/www/html
                fi
                rm -rf "$SM_TMP"
            fi

            rm -rf "${DB_TMP:-}" "${FILES_TMP:-}"
        fi

        # Fix ownership
        chown -R 33:1100 "$INSTALL_DIR/web/app/uploads" "$INSTALL_DIR/web/app/languages"
        chmod -R g+w "$INSTALL_DIR/web/app/uploads" "$INSTALL_DIR/web/app/languages"
    fi

    # ══════════════════════════════════════════════════════
    #  Website restore (if mode is full or web)
    # ══════════════════════════════════════════════════════
    if mode_includes web; then
        if tag_exists "web-files"; then
            log_info "=== Restoring website data ==="
            WF_TMP=$(make_tmp)
            run_restic --retry-lock 5m restore latest --tag web-files --target "$WF_TMP"
            rsync -a "$WF_TMP/" /opt/dockbase/website/public/ 2>/dev/null || true
            rm -rf "$WF_TMP"
            log_info "Website files restored."
        fi

        if tag_exists "web-matomo"; then
            log_info "Restoring web-matomo..."
            WM_TMP=$(make_tmp)
            run_restic --retry-lock 5m restore latest --tag web-matomo --target "$WM_TMP"
            WM_SQL=$(find "$WM_TMP" -name "matomo_web.sql" | head -1)
            [ -n "$WM_SQL" ] && docker exec -i "$DB_CONTAINER" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" matomo_web < "$WM_SQL"
            WM_DATA=$(find "$WM_TMP" -type d -name "data" | head -1)
            if [ -n "$WM_DATA" ]; then
                docker cp "$WM_DATA/." dockbase_matomo_web:/var/www/html/
                docker exec dockbase_matomo_web chown -R www-data:www-data /var/www/html
            fi
            rm -rf "$WM_TMP"
        fi
    fi

    # ══════════════════════════════════════════════════════
    #  Mailcow restore (if mode is full or mail)
    # ══════════════════════════════════════════════════════
    if mode_includes mail; then
        if tag_exists "mailcow"; then
            log_info "=== Restoring Mailcow ==="
            MC_TMP=$(make_tmp)
            run_restic --retry-lock 5m restore latest --tag mailcow --target "$MC_TMP"
            if [ -d "/opt/mailcow" ]; then
                cd /opt/mailcow
                # Use Mailcow's own restore if available
                if [ -f "helper-scripts/backup_and_restore.sh" ]; then
                    MAILCOW_BACKUP_LOCATION="$MC_TMP" bash helper-scripts/backup_and_restore.sh restore || \
                        log_warn "Mailcow restore script failed. Manual restore may be needed."
                else
                    log_warn "Mailcow restore script not found. Copy backup data manually."
                fi
                cd "$INSTALL_DIR"
            fi
            rm -rf "$MC_TMP"
        fi
    fi

    # Mark restore complete
    touch "$INSTALL_DIR/.restore-done"
    log_info "Data restore complete."
fi

# ══════════════════════════════════════════════════════════
#  Post-restore fixups (always run)
# ══════════════════════════════════════════════════════════

# ── Domain Search-Replace (shop only) ────────────────────
if mode_includes shop; then
    if [ -n "${OLD_DOMAIN:-}" ] && [ -n "${SITE_DOMAIN:-}" ] && [ "$OLD_DOMAIN" != "$SITE_DOMAIN" ]; then
        if ! docker exec "$CONTAINER" wp --path=/app/web/wp core is-installed 2>/dev/null; then
            log_warn "WP core not installed — skipping search-replace (likely no DB was restored)."
        else
            log_info "Running WordPress search-replace: ${OLD_DOMAIN} -> ${SITE_DOMAIN}..."
            docker exec "$CONTAINER" wp --path=/app/web/wp search-replace \
                "https://$OLD_DOMAIN" "https://$SITE_DOMAIN" --all-tables --precise

            docker exec "$CONTAINER" wp --path=/app/web/wp search-replace \
                "$OLD_DOMAIN" "$SITE_DOMAIN" --all-tables --precise

            log_info "Updating Matomo shop site URL..."
            docker exec -i "$DB_CONTAINER" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" matomo_shop <<SQLEOF
UPDATE matomo_site SET main_url='https://${SITE_DOMAIN}' WHERE idsite=1;
UPDATE matomo_site SET currency='EUR' WHERE idsite=1;
SQLEOF
            log_info "Domain migration complete."
        fi
    else
        log_info "No domain change detected. Skipping search-replace."
    fi

    # Flush caches
    log_info "Flushing caches..."
    docker exec "$CONTAINER" wp --path=/app/web/wp cache flush 2>/dev/null || true
    docker exec dockbase_keydb keydb-cli FLUSHALL 2>/dev/null || true
fi

# ── Final Healthcheck ─────────────────────────────────────
log_info "Running final healthcheck..."
sleep 5

if mode_includes shop; then
    SITE_STATUS=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/ 2>/dev/null || echo "000")
    if [ "$SITE_STATUS" = "200" ] || [ "$SITE_STATUS" = "302" ]; then
        log_info "Shop responding (HTTP ${SITE_STATUS})."
    else
        log_warn "Shop returned HTTP ${SITE_STATUS}. Check logs."
    fi
fi

log_info ""
log_info "=== Import complete ==="
log_info ""
if mode_includes shop; then
    log_info "Verify shop: curl -I https://${SITE_DOMAIN}"
fi
if mode_includes web; then
    log_info "Verify website: check domains in config/domains.conf"
fi
if mode_includes mail; then
    log_info "Verify mail: curl -I https://${MAIL_HOSTNAME:-mail.shop.example.com}"
fi
