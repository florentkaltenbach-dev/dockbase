#!/bin/bash
# prod-maintenance: weekly OS maintenance pass with smart verification,
# one self-heal attempt, and loud alerting. No AI in the loop — AI on call.
#
# Modes:
#   (default)  full pass: pre-verify -> apt upgrade -> verify (self-heal once)
#              -> schedule reboot if required (post-reboot verify via @reboot cron)
#   verify     verification only (+ self-heal once + alerts) — run after reboots
#
# Alerts: healthchecks.io ping (HEALTHCHECKS_MAINT_URL in config.env, optional)
#         + Linear issue (LINEAR_API_KEY in ~/.bashrc + LINEAR_TEAM_ID below, optional)
set -uo pipefail

cd /opt/dockbase
LOG="/opt/dockbase/logs/maintenance.log"
MODE="${1:-full}"

log() { echo "$(date '+%F %T'): $*" >> "$LOG"; }

cfg() { grep -m1 "^$1=" config.env 2>/dev/null | cut -d= -f2-; }
SITE_DOMAIN="$(cfg SITE_DOMAIN)"
DEPLOY_MODE="$(cfg DEPLOY_MODE)"
HC_URL="$(cfg HEALTHCHECKS_MAINT_URL)"
LINEAR_TEAM_ID="$(cfg LINEAR_TEAM_ID)"

hc_ping() { # $1: "", "/start" or "/fail"
    [ -z "$HC_URL" ] && return 0
    if [ "${1:-}" = "/fail" ]; then
        tail -c 5000 "$LOG" | curl -fsS -m 10 --retry 3 --data-binary @- "${HC_URL}/fail" >/dev/null 2>&1 || true
    else
        curl -fsS -m 10 --retry 3 -X POST "${HC_URL}${1:-}" >/dev/null 2>&1 || true
    fi
}

linear_alert() { # $1: title, $2: body
    local key
    key=$(grep -m1 '^export LINEAR_API_KEY=' ~/.bashrc | cut -d= -f2- | tr -d '"')
    { [ -z "$key" ] || [ -z "$LINEAR_TEAM_ID" ]; } && return 0
    curl -fsS -m 15 https://api.linear.app/graphql \
        -H "Authorization: $key" -H "Content-Type: application/json" \
        --data "$(jq -n --arg t "$1" --arg b "$2" --arg team "$LINEAR_TEAM_ID" \
            '{query: "mutation($t:String!,$b:String!,$team:String!){issueCreate(input:{teamId:$team,title:$t,description:$b,priority:1}){success}}", variables: {t:$t,b:$b,team:$team}}')" \
        >/dev/null 2>&1 || true
}

alert() { # $1: short reason
    log "ALERT: $1"
    hc_ping /fail
    linear_alert "PROD ALERT: $1" "prod-maintenance.sh on $(hostname) at $(date '+%F %T %Z'). Reason: $1. Log tail:
\`\`\`
$(tail -n 30 "$LOG")
\`\`\`"
}

verify() {
    local ok=0
    # Web: status, real page weight, real title
    local out code size
    out=$(curl -s -o /tmp/maint-home.html -w "%{http_code} %{size_download}" --max-time 20 "https://${SITE_DOMAIN}/" || echo "000 0")
    code="${out% *}"; size="${out#* }"
    if [ "$code" != "200" ] || [ "$size" -lt 50000 ] || ! grep -qi "<title>" /tmp/maint-home.html; then
        log "verify FAIL web: code=$code size=$size"; ok=1
    fi
    # Containers: nothing unhealthy or restarting
    local bad
    bad=$(docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -ciE "unhealthy|restarting" || true)
    if [ "$bad" -gt 0 ]; then
        log "verify FAIL containers: $(docker ps -a --format '{{.Names}} {{.Status}}' | grep -iE 'unhealthy|restarting' | head -3)"; ok=1
    fi
    # Mail ports (full/mail mode)
    if [ "$DEPLOY_MODE" = "full" ] || [ "$DEPLOY_MODE" = "mail" ]; then
        for p in 25 465 587 993; do
            timeout 4 bash -c "echo > /dev/tcp/127.0.0.1/$p" 2>/dev/null || { log "verify FAIL mail port $p"; ok=1; }
        done
    fi
    # Disk
    local used
    used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
    [ "$used" -ge 90 ] && { log "verify FAIL disk ${used}%"; ok=1; }
    return $ok
}

self_heal() {
    log "self-heal: force-recreating dockbase containers..."
    docker compose -f docker-compose.shared.yml up -d --force-recreate >> "$LOG" 2>&1
    docker compose up -d --force-recreate >> "$LOG" 2>&1
    sleep 45
}

verify_or_alert() { # $1: phase name
    if verify; then log "verify OK ($1)"; return 0; fi
    log "verify failed ($1) — attempting self-heal"
    self_heal
    if verify; then log "verify OK after self-heal ($1)"; return 0; fi
    alert "verification failed after self-heal ($1) on ${SITE_DOMAIN}"
    return 1
}

if [ "$MODE" = "verify" ]; then
    # Post-reboot / on-demand verification. Give services time to settle.
    sleep 60
    log "=== verify mode ==="
    verify_or_alert "post-reboot" && hc_ping
    exit $?
fi

log "=== weekly maintenance pass ==="
hc_ping /start

if ! verify; then
    alert "pre-existing failure before maintenance — aborting upgrade"
    exit 1
fi
log "pre-verify OK"

log "running apt upgrade..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG" 2>&1
sudo DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    upgrade -y >> "$LOG" 2>&1
log "apt upgrade done (exit $?)"

verify_or_alert "post-upgrade" || exit 1
hc_ping

if [ -f /var/run/reboot-required ]; then
    log "reboot required — rebooting in 2 minutes (post-reboot verify via @reboot cron)"
    sudo shutdown -r +2 "Weekly maintenance reboot" >> "$LOG" 2>&1
else
    log "no reboot required"
fi
log "=== maintenance pass complete ==="
