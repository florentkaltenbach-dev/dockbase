#!/usr/bin/env bash
set -euo pipefail

# Dockbase One-Click Deploy
# Run from your laptop: ./deploy.sh [options] <server-ip>
#
# State is tracked in .deploy-state with mode-prefixed entries.
# Safe to re-run — completed phases are skipped.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
BACKUP_KEY="${SCRIPT_DIR}/backup_key"
STATE_FILE="${SCRIPT_DIR}/.deploy-state"
LOG_FILE="${SCRIPT_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"

# Tee all output to log file
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Log: ${LOG_FILE}"

# ── Parse arguments ─────────────────────────────────────
FRESH=false
RESET=false
RESET_MODE=""
DEPLOY_MODE="full"
DO_RESTORE=false
CONFIGURE_ONLY=false
VERBOSE=false

POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --fresh) FRESH=true; shift ;;
        --reset) RESET=true; shift ;;
        --reset-mode)
            RESET_MODE="${2:-}"
            [ -z "$RESET_MODE" ] && { echo "ERROR: --reset-mode requires a mode argument"; exit 1; }
            shift 2 ;;
        --mode)
            DEPLOY_MODE="${2:-}"
            [ -z "$DEPLOY_MODE" ] && { echo "ERROR: --mode requires an argument (full|shop|mail|web)"; exit 1; }
            shift 2 ;;
        --restore) DO_RESTORE=true; shift ;;
        --configure) CONFIGURE_ONLY=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

# Validate mode
case "$DEPLOY_MODE" in
    full|shop|mail|web) ;;
    *) echo "ERROR: Invalid mode '${DEPLOY_MODE}'. Use: full, shop, mail, web"; exit 1 ;;
esac

# Helper: check if current mode includes a stack
mode_includes() {
    local stack="$1"
    case "$DEPLOY_MODE" in
        full) return 0 ;;
        "$stack") return 0 ;;
        *) return 1 ;;
    esac
}

if [ ${#POSITIONAL[@]} -lt 1 ] && [ "$CONFIGURE_ONLY" = false ]; then
    echo "Usage: ./deploy.sh [options] <server-ip>"
    echo ""
    echo "Options:"
    echo "  --mode <mode>       Deploy mode: full (default), shop, mail, web"
    echo "  --restore           Run data restore after setup"
    echo "  --fresh             Clear known_hosts for this IP"
    echo "  --reset             Clear all deploy state"
    echo "  --reset-mode <mode> Clear state for one mode only"
    echo "  --configure         Run config wizard only, don't deploy"
    echo "  --verbose           Show detailed output"
    echo ""
    echo "Modes:"
    echo "  full  — shared infra + shop + mail + website"
    echo "  shop  — shared infra + shop only"
    echo "  mail  — shared infra + mail only"
    echo "  web   — shared infra + website only"
    echo ""
    echo "State is saved in .deploy-state. Re-runs skip completed phases."
    exit 1
fi

# ── State tracking ────────────────────────────────────────
phase_done() {
    grep -qx "${DEPLOY_MODE}:$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    echo "${DEPLOY_MODE}:$1" >> "$STATE_FILE"
    echo ""
    echo "  >>> checkpoint: ${DEPLOY_MODE}:$1 done <<<"
    echo ""
}

last_checkpoint() {
    if [ -f "$STATE_FILE" ]; then
        tail -1 "$STATE_FILE"
    else
        echo "(none)"
    fi
}

if [ "$RESET" = true ]; then
    echo "Clearing all deploy state (--reset)..."
    rm -f "$STATE_FILE"
    FRESH=true
fi

if [ -n "$RESET_MODE" ]; then
    echo "Clearing state for mode '${RESET_MODE}'..."
    if [ -f "$STATE_FILE" ]; then
        sed -i "/^${RESET_MODE}:/d" "$STATE_FILE"
    fi
fi

# ── Ensure config.env exists ────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No config.env found next to deploy.sh."
    echo "Generating from template..."
    cp "${REPO_DIR}/config.env.example" "$CONFIG_FILE"

    generate_password() { openssl rand -base64 24 | tr -d '/+=' | head -c 32; }

    sed -i "s/^MYSQL_ROOT_PASSWORD=changeme$/MYSQL_ROOT_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i "s/^MYSQL_PASSWORD=changeme$/MYSQL_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i "s/^MATOMO_SHOP_DATABASE_PASSWORD=changeme$/MATOMO_SHOP_DATABASE_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i "s/^MATOMO_WEB_DATABASE_PASSWORD=changeme$/MATOMO_WEB_DATABASE_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i "s/^RESTIC_PASSWORD=changeme$/RESTIC_PASSWORD=$(generate_password)/" "$CONFIG_FILE"

    for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        sed -i "s/^${key}=$/${key}=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)/" "$CONFIG_FILE"
    done

    # Set deploy mode in config
    sed -i "s/^DEPLOY_MODE=.*$/DEPLOY_MODE=${DEPLOY_MODE}/" "$CONFIG_FILE"

    echo ""
    echo "Generated: ${CONFIG_FILE}"
    echo ""
    echo ">>> EDIT THIS FILE NOW <<<"
    echo "At minimum, set:"
    echo "  SITE_DOMAIN       — your shop domain"
    echo "  TLS_EMAIL         — your email for Let's Encrypt"
    echo "  SERVER_IP         — target server IP"
    echo "  OLD_DOMAIN        — previous domain (for migration)"
    echo ""
    read -r -p "Press Enter when ready (or Ctrl+C to abort)..."
fi

if [ "$CONFIGURE_ONLY" = true ]; then
    echo "Config file: ${CONFIG_FILE}"
    echo "Done (--configure mode)."
    exit 0
fi

source "$CONFIG_FILE"
: "${SITE_DOMAIN:?SITE_DOMAIN not set in config.env}"
: "${TLS_EMAIL:?TLS_EMAIL not set in config.env}"

# Ensure DEPLOY_MODE in config.env matches CLI
if [ "${DEPLOY_MODE}" != "${DEPLOY_MODE_FROM_FILE:-$DEPLOY_MODE}" ]; then
    sed -i "s/^DEPLOY_MODE=.*$/DEPLOY_MODE=${DEPLOY_MODE}/" "$CONFIG_FILE"
fi

SERVER_IP="${POSITIONAL[0]:-${SERVER_IP:-}}"
SERVER_IP="${SERVER_IP#*@}"
: "${SERVER_IP:?SERVER_IP not set}"

if [ -f "$STATE_FILE" ]; then
    echo "Last checkpoint: $(last_checkpoint)"
    echo "Completed: $(paste -sd', ' "$STATE_FILE")"
    echo ""
fi

echo ""
echo "=== Dockbase Deploy ==="
echo "Mode:    ${DEPLOY_MODE}"
echo "Server:  ${SERVER_IP}"
echo "Domain:  ${SITE_DOMAIN}"
echo "Config:  ${CONFIG_FILE}"
if mode_includes mail; then
    echo "Mail:    ${MAIL_HOSTNAME:-not set}"
fi
echo ""

# ── Detect SSH key ────────────────────────────────────────
SSH_KEY=""
for candidate in "${SCRIPT_DIR}/id_ed25519_hetzner" \
                 ~/.ssh/id_ed25519_hetzner \
                 ~/.ssh/id_ed25519 \
                 ~/.ssh/id_rsa; do
    if [ -f "$candidate" ]; then
        SSH_KEY="$candidate"
        break
    fi
done

# Build SSH option arrays (arrays handle paths with spaces correctly)
SSH_OPTS_PROBE=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes)
SSH_OPTS_RUN=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
SCP_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS_PROBE+=(-i "$SSH_KEY")
    SSH_OPTS_RUN+=(-i "$SSH_KEY")
    SCP_OPTS+=(-i "$SSH_KEY")
    echo "Using SSH key: ${SSH_KEY}"
fi

if [ "$FRESH" = true ]; then
    echo "Clearing known_hosts for ${SERVER_IP} (--fresh)..."
    ssh-keygen -R "$SERVER_IP" 2>/dev/null || true
fi

# ── Helpers ─────────────────────────────────────────────

ssh_probe() {
    local user="$1"; shift
    ssh "${SSH_OPTS_PROBE[@]}" "${user}@${SERVER_IP}" "$@" < /dev/null
}

ssh_as() {
    local user="$1"; shift
    ssh "${SSH_OPTS_RUN[@]}" "${user}@${SERVER_IP}" "$@"
}

run_script() {
    local user="$1" phase_name="$2" local_script="$3"
    shift 3
    local env_prefix="${*:-}"

    echo "[${phase_name}] Uploading $(basename "$local_script")..."

    # Upload lib/ directory so scripts can source common.sh
    local script_parent
    script_parent="$(dirname "$local_script")"
    if [ -d "${script_parent}/lib" ]; then
        ssh "${SSH_OPTS_RUN[@]}" "${user}@${SERVER_IP}" "mkdir -p /tmp/lib"
        for lib_file in "${script_parent}"/lib/*.sh; do
            [ -f "$lib_file" ] || continue
            scp "${SCP_OPTS[@]}" "$lib_file" "${user}@${SERVER_IP}:/tmp/lib/$(basename "$lib_file")"
        done
    fi

    scp "${SCP_OPTS[@]}" "$local_script" "${user}@${SERVER_IP}:/tmp/_phase_script.sh"

    echo "[${phase_name}] Running..."
    local rc=0
    ssh "${SSH_OPTS_RUN[@]}" "${user}@${SERVER_IP}" "${env_prefix:+$env_prefix }bash /tmp/_phase_script.sh; _rc=\$?; rm -rf /tmp/_phase_script.sh /tmp/lib; exit \$_rc" || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo ""
        echo "ERROR: ${phase_name} failed (exit code ${rc})."
        echo "SSH into the server to investigate:"
        echo "  ssh deploy@${SERVER_IP}"
        exit "$rc"
    fi
}

run_remote_cmd() {
    local user="$1" phase_name="$2"; shift 2
    echo "[${phase_name}] Running..."
    local rc=0
    ssh "${SSH_OPTS_RUN[@]}" "${user}@${SERVER_IP}" "$@" || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo ""
        echo "ERROR: ${phase_name} failed (exit code ${rc})."
        exit "$rc"
    fi
}

wait_for_ssh() {
    local user="$1"
    local max_wait=60
    local waited=0
    local probe_err=""
    echo "Waiting for SSH as ${user}@${SERVER_IP}..."
    while true; do
        if probe_err=$(ssh_probe "$user" "echo ok" 2>&1); then
            break
        fi
        sleep 5
        waited=$((waited + 5))
        if [ $waited -ge $max_wait ]; then
            echo ""
            echo "Last SSH error:"
            echo "$probe_err"
            echo ""
            echo "ERROR: SSH not available after ${max_wait}s"
            echo "Full log: ${LOG_FILE}"
            exit 1
        fi
        echo "  ...waiting (${waited}s)"
    done
    echo "SSH ready."
}

upload_file() {
    local src="$1" dest="$2" user="${3:-deploy}" mode="${4:-644}"
    scp "${SCP_OPTS[@]}" "$src" "${user}@${SERVER_IP}:/tmp/_upload"
    ssh_as "$user" "sudo mv /tmp/_upload ${dest} && sudo chmod ${mode} ${dest}"
}

# ── Detect SSH user ──────────────────────────────────────
echo "Waiting for SSH on ${SERVER_IP}..."
READY_USER=""
max_wait=30
waited=0
host_key_fixed=false
while [ -z "$READY_USER" ]; do
    probe_err=""
    if probe_err=$(ssh_probe "deploy" "echo ok" 2>&1); then
        READY_USER="deploy"
    elif probe_err=$(ssh_probe "root" "echo ok" 2>&1); then
        READY_USER="root"
    else
        # Auto-fix host key change (once)
        if [ "$host_key_fixed" = false ] && echo "$probe_err" | grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED"; then
            echo "  Host key changed — auto-clearing known_hosts for ${SERVER_IP}..."
            ssh-keygen -R "$SERVER_IP" 2>/dev/null || true
            host_key_fixed=true
            continue  # retry immediately
        fi

        sleep 5
        waited=$((waited + 5))
        if [ $waited -ge $max_wait ]; then
            echo ""
            echo "Last SSH error:"
            echo "$probe_err"
            echo ""
            echo "ERROR: SSH not available as root or deploy after ${max_wait}s"
            echo "Full log: ${LOG_FILE}"
            exit 1
        fi
        echo "  ...waiting (${waited}s)"
    fi
done
echo "SSH ready (${READY_USER})."

# ══════════════════════════════════════════════════════════
#  Phase 1: Harden
# ══════════════════════════════════════════════════════════
if phase_done "harden"; then
    echo "=== Phase 1: Server Hardening — already done, skipping ==="
elif [ "$READY_USER" = "root" ]; then
    echo "=== Phase 1: Server Hardening ==="
    run_script root "Phase 1: Harden" "${SCRIPT_DIR}/harden.sh" "export DEBIAN_FRONTEND=noninteractive DEPLOY_MODE=${DEPLOY_MODE};"
    mark_done "harden"

    echo ""
    echo "Rebooting server..."
    ssh_as deploy "sudo reboot" || true
    sleep 5
    wait_for_ssh "deploy"
    READY_USER="deploy"
else
    echo "=== Phase 1: Server Hardening — deploy user exists, skipping ==="
    mark_done "harden"
fi

# ══════════════════════════════════════════════════════════
#  Phase 2: Shared Setup
# ══════════════════════════════════════════════════════════
if phase_done "setup-shared"; then
    echo "=== Phase 2: Shared Setup — already done, skipping ==="
else
    echo ""
    echo "=== Phase 2: Shared Setup ==="

    # Upload config files
    echo "Uploading config.env..."
    upload_file "$CONFIG_FILE" "/tmp/dockbase-config.env" deploy 600

    if [ -f "$BACKUP_KEY" ]; then
        echo "Uploading backup_key..."
        upload_file "$BACKUP_KEY" "/tmp/dockbase-backup_key" deploy 600
    else
        echo "No backup_key found — skipping."
    fi

    # Upload domain configs if present
    if [ -f "${REPO_DIR}/config/domains.conf" ]; then
        echo "Uploading domains.conf..."
        upload_file "${REPO_DIR}/config/domains.conf" "/tmp/dockbase-domains.conf" deploy 644
    fi
    if [ -f "${REPO_DIR}/config/mail-domains.conf" ]; then
        echo "Uploading mail-domains.conf..."
        upload_file "${REPO_DIR}/config/mail-domains.conf" "/tmp/dockbase-mail-domains.conf" deploy 644
    fi

    # Run setup.sh
    run_script deploy "Phase 2: Setup" "${SCRIPT_DIR}/setup.sh" "sudo DEBIAN_FRONTEND=noninteractive"
    mark_done "setup-shared"
fi

# ── Sync latest code to server ────────────────────────────
echo ""
echo "Syncing latest code to server..."
ssh_as deploy "cd /opt/dockbase && git checkout -- . 2>/dev/null; git pull --ff-only" || true

# ══════════════════════════════════════════════════════════
#  Phase 3: Shared Caddy
# ══════════════════════════════════════════════════════════
if phase_done "setup-caddy"; then
    echo "=== Phase 3: Shared Caddy — already done, skipping ==="
else
    echo ""
    echo "=== Phase 3: Shared Caddy ==="
    run_remote_cmd deploy "Phase 3: Caddy" "cd /opt/dockbase && sudo bash infra/setup-caddy.sh"
    mark_done "setup-caddy"
fi

# ══════════════════════════════════════════════════════════
#  Phase 4: Shop (if mode includes shop)
# ══════════════════════════════════════════════════════════
if mode_includes shop; then
    if phase_done "setup-shop"; then
        echo "=== Phase 4: Shop — already done, skipping ==="
    else
        echo ""
        echo "=== Phase 4: Shop Stack ==="
        run_remote_cmd deploy "Phase 4: Shop" "cd /opt/dockbase && sudo bash infra/setup-shop.sh"
        mark_done "setup-shop"
    fi
else
    echo "=== Phase 4: Shop — skipped (mode: ${DEPLOY_MODE}) ==="
fi

# ══════════════════════════════════════════════════════════
#  Phase 5: Mailcow (if mode includes mail)
# ══════════════════════════════════════════════════════════
if mode_includes mail; then
    if phase_done "setup-mailcow"; then
        echo "=== Phase 5: Mailcow — already done, skipping ==="
    else
        echo ""
        echo "=== Phase 5: Mailcow ==="
        run_remote_cmd deploy "Phase 5: Mailcow" "cd /opt/dockbase && sudo bash infra/setup-mailcow.sh"
        mark_done "setup-mailcow"

        # Sync Caddy TLS certs into Mailcow (for SMTP/IMAP TLS)
        echo ""
        echo "=== Phase 5b: Cert Sync ==="
        echo "Waiting for Caddy to provision cert for ${MAIL_HOSTNAME}..."
        sleep 10
        run_remote_cmd deploy "Phase 5b: Cert Sync" "cd /opt/dockbase && sudo bash infra/sync-certs.sh" || {
            echo "  Cert sync failed — can be run later with: sudo bash /opt/dockbase/infra/sync-certs.sh"
        }
    fi
else
    echo "=== Phase 5: Mailcow — skipped (mode: ${DEPLOY_MODE}) ==="
fi

# ══════════════════════════════════════════════════════════
#  Phase 6: Website (if mode includes web)
# ══════════════════════════════════════════════════════════
if mode_includes web; then
    if phase_done "setup-website"; then
        echo "=== Phase 6: Website — already done, skipping ==="
    else
        echo ""
        echo "=== Phase 6: Website ==="
        run_remote_cmd deploy "Phase 6: Website" "cd /opt/dockbase && sudo bash infra/setup-website.sh"
        mark_done "setup-website"
    fi
else
    echo "=== Phase 6: Website — skipped (mode: ${DEPLOY_MODE}) ==="
fi

# ══════════════════════════════════════════════════════════
#  Phase 7: Backup & Cron
# ══════════════════════════════════════════════════════════
if phase_done "backup-cron"; then
    echo "=== Phase 7: Backup & Cron — already done, skipping ==="
else
    echo ""
    echo "=== Phase 7: Backup & Cron ==="

    # Build cron entries based on mode
    CRON_ENTRIES=""
    if mode_includes shop; then
        CRON_ENTRIES+="# Dockbase: WordPress auto-update (04:00 daily)\n"
        CRON_ENTRIES+="0 4 * * * /opt/dockbase/scripts/wp-update.sh >> /opt/dockbase/logs/wp-updates.log 2>&1\n"
    fi
    CRON_ENTRIES+="# Dockbase: Backup (04:30 daily)\n"
    CRON_ENTRIES+="30 4 * * * /opt/dockbase/config/backup/scripts/backup.sh\n"

    if mode_includes mail; then
        CRON_ENTRIES+="# Dockbase: Cert sync for Mailcow (weekly)\n"
        CRON_ENTRIES+="0 5 * * 1 /opt/dockbase/infra/sync-certs.sh >> /opt/dockbase/logs/cert-sync.log 2>&1\n"
    fi

    # shellcheck disable=SC2086
    ssh_as deploy "
        CRON_TMP=\$(mktemp)
        chmod 644 \"\$CRON_TMP\"
        crontab -l 2>/dev/null | grep -v '/opt/dockbase/' > \"\$CRON_TMP\" || true
        printf '${CRON_ENTRIES}' >> \"\$CRON_TMP\"
        crontab \"\$CRON_TMP\"
        rm -f \"\$CRON_TMP\"
        echo 'Cron jobs installed.'
    "
    mark_done "backup-cron"
fi

# ══════════════════════════════════════════════════════════
#  Phase 8: Restore (only with --restore)
# ══════════════════════════════════════════════════════════
if [ "$DO_RESTORE" = true ]; then
    if phase_done "restore"; then
        echo "=== Phase 8: Restore — already done, skipping ==="
    elif [ -f "$BACKUP_KEY" ]; then
        echo ""
        echo "=== Phase 8: Data Restore ==="
        IMPORT_FLAGS=""
        if ssh "${SSH_OPTS_RUN[@]}" "deploy@${SERVER_IP}" "test -f /opt/dockbase/.restore-done" 2>/dev/null; then
            IMPORT_FLAGS="--skip-restore"
            echo "Data already restored — running search-replace only."
        fi
        run_remote_cmd deploy "Phase 8: Restore" "cd /opt/dockbase && git pull && sudo bash infra/import.sh $IMPORT_FLAGS"
        mark_done "restore"
    else
        echo ""
        echo "Skipping restore (no backup_key)."
        echo "To restore later:"
        echo "  scp backup_key deploy@${SERVER_IP}:/opt/dockbase/config/backup/backup_key"
        echo "  ssh deploy@${SERVER_IP} 'cd /opt/dockbase && sudo bash infra/import.sh'"
    fi
else
    echo "=== Phase 8: Restore — skipped (use --restore to enable) ==="
fi

# ══════════════════════════════════════════════════════════
#  Phase 9: Verify
# ══════════════════════════════════════════════════════════
echo ""
echo "=== Phase 9: Verification ==="

# Show running containers
ssh_as deploy "cd /opt/dockbase && sudo docker compose ps 2>/dev/null; sudo docker compose -f docker-compose.shared.yml ps 2>/dev/null" || true

# Memory usage
echo ""
echo "=== Memory Usage ==="
ssh_as deploy "free -h; echo ''; sudo docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}' 2>/dev/null | sort -k2 -h" || true

# HTTPS checks
echo ""
echo "Checking HTTPS endpoints..."
sleep 3

if mode_includes shop; then
    if curl -sSf -o /dev/null -w "%{http_code}" --connect-timeout 10 "https://${SITE_DOMAIN}" 2>/dev/null; then
        echo "  https://${SITE_DOMAIN} — OK"
    else
        echo "  https://${SITE_DOMAIN} — not yet reachable"
    fi
fi

if mode_includes mail && [ -n "${MAIL_HOSTNAME:-}" ]; then
    if curl -sSf -o /dev/null -w "%{http_code}" --connect-timeout 10 "https://${MAIL_HOSTNAME}" 2>/dev/null; then
        echo "  https://${MAIL_HOSTNAME} — OK"
    else
        echo "  https://${MAIL_HOSTNAME} — not yet reachable"
    fi
fi

mark_done "verify"

# ── Summary ────────────────────────────────────────────
echo ""
echo "========================================="
echo "  Dockbase Deploy Complete!"
echo "========================================="
echo ""
echo "  Mode:    ${DEPLOY_MODE}"
echo "  Server:  ${SERVER_IP}"

if mode_includes shop; then
    echo "  Shop:    https://${SITE_DOMAIN}"
    echo "  Matomo:  https://matomo.${SITE_DOMAIN%%.*}.${SITE_DOMAIN#*.}"
fi

if mode_includes mail; then
    echo "  Mail:    https://${MAIL_HOSTNAME:-}"
fi

if mode_includes web; then
    echo "  Website: (see config/domains.conf for website domains)"
fi

echo ""
echo "  SSH:     ssh deploy@${SERVER_IP}"
echo "  Secrets: ${CONFIG_FILE}"
echo "  State:   ${STATE_FILE}"
echo "  Log:     ${LOG_FILE}"
echo "  Keep both files safe!"
echo ""
