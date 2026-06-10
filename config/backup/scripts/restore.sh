#!/bin/bash
# Dockbase Restore Script
# Restores individual backup tags from Restic.
# Usage: ./restore.sh [tag] [snapshot-id]
# Tags: shop-db, shop-files, shop-matomo, web-files, web-matomo, mailcow
# Also accepts legacy tags: db, uploads, languages, matomo
# If no tag given, lists all snapshots.

set -Eeuo pipefail

# Keep Restic user context consistent
if [ "$(id -un)" != "deploy" ]; then
    exec sudo -u deploy -H bash "$0" "$@"
fi

cd /opt/dockbase

load_env_var() {
    local key="$1"
    local value
    value="$(grep -m1 "^${key}=" config.env 2>/dev/null | cut -d= -f2- || true)"
    if [ -z "$value" ]; then
        echo "ERROR: Missing ${key} in /opt/dockbase/config.env" >&2
        exit 1
    fi
    export "${key}=${value}"
}

load_env_var RESTIC_REPOSITORY
load_env_var RESTIC_PASSWORD

# Remove stale locks
restic unlock >/dev/null 2>&1 || true

ALL_TAGS="shop-db shop-files shop-matomo web-files web-matomo mailcow db uploads languages matomo"

if [ -z "${1:-}" ]; then
    echo "Available snapshots:"
    echo ""
    for tag in $ALL_TAGS; do
        count=$(restic --retry-lock 5m snapshots --tag "$tag" --json 2>/dev/null | jq length 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            echo "=== ${tag} (${count} snapshots) ==="
            restic --retry-lock 5m snapshots --tag "$tag" 2>/dev/null
            echo ""
        fi
    done
    echo "Usage: $0 <tag> [snapshot-id]"
    echo "Tags: shop-db, shop-files, shop-matomo, web-files, web-matomo, mailcow"
    echo "Legacy: db, uploads, languages, matomo"
    echo "If snapshot-id is omitted, restores 'latest' for that tag."
    exit 0
fi

TAG="$1"
SNAPSHOT_ID="${2:-latest}"
TARGET_DIR="/tmp/restore-${TAG}-$(date +%Y%m%d-%H%M%S)"

# Validate tag
case "$TAG" in
    shop-db|shop-files|shop-matomo|web-files|web-matomo|mailcow) ;;
    db|uploads|languages|matomo) echo "Note: Using legacy tag '${TAG}'." ;;
    *)
        echo "ERROR: Unknown tag '$TAG'." >&2
        echo "Valid tags: shop-db, shop-files, shop-matomo, web-files, web-matomo, mailcow" >&2
        echo "Legacy tags: db, uploads, languages, matomo" >&2
        exit 1
        ;;
esac

echo "Restoring tag '${TAG}' (snapshot: ${SNAPSHOT_ID}) to ${TARGET_DIR}..."
mkdir -p "$TARGET_DIR"
restic --retry-lock 5m restore "$SNAPSHOT_ID" --tag "$TAG" --target "$TARGET_DIR"

echo ""
echo "Restore complete. Files at: $TARGET_DIR"
echo ""

case "$TAG" in
    shop-db)
        echo "To import WordPress DB:"
        echo "  docker compose exec -T mariadb mariadb -u root -p\$MYSQL_ROOT_PASSWORD \$MYSQL_DATABASE < ${TARGET_DIR}/.../\$MYSQL_DATABASE.sql"
        ;;
    db)
        echo "To import WordPress DB (legacy):"
        echo "  docker compose exec -T mariadb mariadb -u root -p\$MYSQL_ROOT_PASSWORD \$MYSQL_DATABASE < ${TARGET_DIR}/backups/db/\$MYSQL_DATABASE.sql"
        echo ""
        echo "To import Matomo DB (legacy — into matomo_shop):"
        echo "  docker compose exec -T mariadb mariadb -u root -p\$MYSQL_ROOT_PASSWORD matomo_shop < ${TARGET_DIR}/backups/db/matomo.sql"
        ;;
    shop-files)
        echo "To restore shop files:"
        echo "  rsync -a --delete ${TARGET_DIR}/.../uploads/ /opt/dockbase/web/app/uploads/"
        echo "  rsync -a --delete ${TARGET_DIR}/.../languages/ /opt/dockbase/web/app/languages/"
        echo "  chown -R 33:1100 /opt/dockbase/web/app/uploads /opt/dockbase/web/app/languages"
        ;;
    uploads)
        echo "To restore uploads (legacy):"
        echo "  rsync -a --delete ${TARGET_DIR}/backups/uploads/ /opt/dockbase/web/app/uploads/"
        echo "  chown -R 33:1100 /opt/dockbase/web/app/uploads"
        ;;
    languages)
        echo "To restore languages (legacy):"
        echo "  rsync -a --delete ${TARGET_DIR}/backups/languages/ /opt/dockbase/web/app/languages/"
        echo "  chown -R 33:1100 /opt/dockbase/web/app/languages"
        ;;
    shop-matomo)
        echo "To restore shop Matomo:"
        echo "  docker compose exec -T mariadb mariadb -u root -p\$MYSQL_ROOT_PASSWORD matomo_shop < ${TARGET_DIR}/.../matomo_shop.sql"
        echo "  docker cp ${TARGET_DIR}/.../data/. dockbase_matomo_shop:/var/www/html/"
        ;;
    matomo)
        echo "To restore Matomo (legacy — into matomo-shop):"
        echo "  docker cp ${TARGET_DIR}/backups/matomo/. dockbase_matomo_shop:/var/www/html/"
        ;;
    web-files)
        echo "To restore website files:"
        echo "  rsync -a --delete ${TARGET_DIR}/.../ /opt/dockbase/website/public/"
        ;;
    web-matomo)
        echo "To restore web Matomo:"
        echo "  docker compose exec -T mariadb mariadb -u root -p\$MYSQL_ROOT_PASSWORD matomo_web < ${TARGET_DIR}/.../matomo_web.sql"
        echo "  docker cp ${TARGET_DIR}/.../data/. dockbase_matomo_web:/var/www/html/"
        ;;
    mailcow)
        echo "To restore Mailcow:"
        echo "  Use Mailcow's own restore script:"
        echo "  cd /opt/mailcow && bash helper-scripts/backup_and_restore.sh restore"
        ;;
esac
