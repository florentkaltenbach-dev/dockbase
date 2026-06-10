#!/usr/bin/env bash
set -euo pipefail

# Dockbase Phase 3: Shared Caddy + CrowdSec
# Sets up the shared edge reverse proxy and security infrastructure.
# Run as root on the server.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_config

log_info "=== Setting up shared Caddy edge ==="

# ── Create external Docker network ──────────────────────
if ! docker network inspect "${DOCKBASE_NETWORK}" &>/dev/null; then
    docker network create "${DOCKBASE_NETWORK}"
    log_info "Created Docker network: ${DOCKBASE_NETWORK}"
else
    log_info "Docker network ${DOCKBASE_NETWORK} already exists."
fi

# ── Create required directories ─────────────────────────
mkdir -p /opt/dockbase/logs/caddy
mkdir -p /opt/dockbase/website/public
chown -R deploy:dockbase /opt/dockbase/logs
chown -R deploy:dockbase /opt/dockbase/website

# Place a placeholder if website dir is empty
if [ ! -f /opt/dockbase/website/public/index.html ]; then
    cat > /opt/dockbase/website/public/index.html <<'HTML'
<!DOCTYPE html>
<html lang="de">
<head><meta charset="utf-8"><title>Coming Soon</title></head>
<body><h1>Coming Soon</h1><p>Website coming soon.</p></body>
</html>
HTML
    log_info "Placed placeholder index.html"
fi

# ── Generate Caddyfile from domains.conf ────────────────
log_info "Generating Caddyfile from domains.conf..."
bash "${SCRIPT_DIR}/generate-caddyfile.sh"

# ── Start shared infrastructure ─────────────────────────
log_info "Starting shared Caddy and CrowdSec..."
cd "${INSTALL_DIR}"
docker compose -f docker-compose.shared.yml up -d

# ── Wait for Caddy to be ready ──────────────────────────
log_info "Waiting for Caddy to start..."
local_wait=0
while ! docker exec dockbase_caddy caddy version &>/dev/null; do
    sleep 2
    local_wait=$((local_wait + 2))
    if [ "$local_wait" -ge 60 ]; then
        log_error "Caddy did not start within 60s"
        docker compose -f docker-compose.shared.yml logs caddy
        exit 1
    fi
done
log_info "Caddy is running."

# ── CrowdSec enrollment ────────────────────────────────
if [ -n "${CROWDSEC_ENROLL_KEY:-}" ]; then
    log_info "Enrolling CrowdSec..."
    docker exec dockbase_crowdsec cscli console enroll "${CROWDSEC_ENROLL_KEY}" 2>/dev/null || true
fi

log_info "Shared edge setup complete."
