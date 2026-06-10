#!/usr/bin/env bash
set -euo pipefail

# Dockbase Phase 6: Website stack
# Ensures the static website directory exists and matomo-web is running.
# Run as root on the server.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_config

log_info "=== Setting up website stack ==="

# ── Ensure website directory exists ─────────────────────
WEBSITE_DIR="/opt/dockbase/website/public"
mkdir -p "$WEBSITE_DIR"
chown -R deploy:dockbase "$WEBSITE_DIR"

if [ ! -f "${WEBSITE_DIR}/index.html" ]; then
    cat > "${WEBSITE_DIR}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="de">
<head><meta charset="utf-8"><title>Coming Soon</title></head>
<body><h1>Coming Soon</h1><p>Website coming soon.</p></body>
</html>
HTML
    log_info "Placed placeholder index.html"
else
    log_info "Website content already present."
fi

# ── Start matomo-web ────────────────────────────────────
cd "${INSTALL_DIR}"
log_info "Starting matomo-web service..."
docker compose up -d matomo-web

# ── Verify website routes ──────────────────────────────
log_info "Verifying website domains through shared Caddy..."
DOMAINS_FILE="${INSTALL_DIR}/config/domains.conf"

if [ -f "$DOMAINS_FILE" ]; then
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        domain=$(echo "$line" | awk '{print $1}')
        backend=$(echo "$line" | awk '{print $2}')
        [ "$backend" = "website" ] || continue

        # Test via Host header against localhost
        http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
            -H "Host: ${domain}" \
            --connect-timeout 5 \
            http://localhost/ 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ]; then
            log_info "  ${domain} -> OK (${http_code})"
        else
            log_warn "  ${domain} -> ${http_code} (may need DNS or Caddy reload)"
        fi
    done < "$DOMAINS_FILE"
fi

log_info "Website stack setup complete."
