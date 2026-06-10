#!/bin/bash
# Dockbase Setup — Phase 2: Shared prerequisites
# Installs Docker, clones the repo, configures backup access.
# Stack-specific setup is handled by setup-caddy.sh, setup-shop.sh, etc.
# Run as root after harden.sh.
# Usage: sudo bash setup.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

REPO_URL="${REPO_URL:-https://github.com/florentkaltenbach-dev/dockbase.git}"

echo "=== Dockbase Setup ==="

# ── Docker CE ─────────────────────────────────────────────
echo "Installing Docker CE..."
if ! command -v docker &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    usermod -aG docker deploy
    systemctl enable docker
    echo "Docker installed."
else
    echo "Docker already installed, skipping."
fi

# ── Additional Tools ──────────────────────────────────────
echo "Installing restic, git, gh, rsync..."
apt-get install -y -qq restic git rsync

# GitHub CLI
if ! command -v gh &>/dev/null; then
    (type -p wget >/dev/null || apt-get install -y -qq wget) \
        && mkdir -p -m 755 /etc/apt/keyrings \
        && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
        && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && apt-get update -qq \
        && apt-get install -y -qq gh
fi

# ── Clone Repository ─────────────────────────────────────
echo "Cloning repository to ${INSTALL_DIR}..."
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "Repository already exists at ${INSTALL_DIR}, pulling latest..."
    sudo -u deploy git -C "$INSTALL_DIR" checkout -- . 2>/dev/null || true
    sudo -u deploy git -C "$INSTALL_DIR" pull --ff-only
elif [ -d "$INSTALL_DIR" ]; then
    echo "Directory exists but is not a git repo — removing stale directory..."
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    chown deploy:project "$INSTALL_DIR"
    sudo -u deploy git clone "$REPO_URL" "$INSTALL_DIR"
else
    mkdir -p "$INSTALL_DIR"
    chown deploy:project "$INSTALL_DIR"
    sudo -u deploy git clone "$REPO_URL" "$INSTALL_DIR"
fi
chown deploy:project "$INSTALL_DIR"

# ── Move staged config files from /tmp ───────────────────
if [ -f /tmp/dockbase-config.env ]; then
    mv /tmp/dockbase-config.env "$INSTALL_DIR/config.env"
    echo "Moved config.env into place."
fi
if [ -f /tmp/dockbase-backup_key ]; then
    mkdir -p "$INSTALL_DIR/config/backup"
    mv /tmp/dockbase-backup_key "$INSTALL_DIR/config/backup/backup_key"
    echo "Moved backup_key into place."
fi
if [ -f /tmp/dockbase-domains.conf ]; then
    mv /tmp/dockbase-domains.conf "$INSTALL_DIR/config/domains.conf"
    echo "Moved domains.conf into place."
fi
if [ -f /tmp/dockbase-mail-domains.conf ]; then
    mv /tmp/dockbase-mail-domains.conf "$INSTALL_DIR/config/mail-domains.conf"
    echo "Moved mail-domains.conf into place."
fi

# ── Ownership & Permissions ──────────────────────────────
echo "Setting ownership and permissions..."
chown -R deploy:project "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod g+s {} +

mkdir -p "$INSTALL_DIR/logs" "$INSTALL_DIR/logs/frankenphp"
chown -R deploy:dockbase "$INSTALL_DIR/logs"
chmod 2775 "$INSTALL_DIR/logs" "$INSTALL_DIR/logs/frankenphp"

mkdir -p "$INSTALL_DIR/backups/db" "$INSTALL_DIR/backups/uploads"
chown -R deploy:project "$INSTALL_DIR/backups"

mkdir -p "$INSTALL_DIR/web/app/uploads" "$INSTALL_DIR/web/app/languages"
chown -R 33:1100 "$INSTALL_DIR/web/app/uploads" "$INSTALL_DIR/web/app/languages"
chmod 2775 "$INSTALL_DIR/web/app/uploads" "$INSTALL_DIR/web/app/languages"

# ── config.env ────────────────────────────────────────────
CONFIG_ENV="$INSTALL_DIR/config.env"
if [ ! -f "$CONFIG_ENV" ]; then
    echo ""
    echo "No config.env found — launching interactive configuration wizard..."
    echo ""
    bash "$INSTALL_DIR/infra/configure.sh" "$INSTALL_DIR"

    if [ ! -f "$CONFIG_ENV" ]; then
        echo "ERROR: ${CONFIG_ENV} still not found after configure." >&2
        exit 1
    fi
else
    echo "Existing config.env found, using it."
fi

chmod 0600 "$CONFIG_ENV"
chown deploy:deploy "$CONFIG_ENV"

# Source all config vars
set -a
source "$CONFIG_ENV"
set +a

# Create .env symlink for Docker Compose
ln -sf config.env "$INSTALL_DIR/.env"

# ── Inject DB passwords into init.sql ────────────────────
INIT_SQL="$INSTALL_DIR/config/mariadb/init.sql"
if [ -n "${MATOMO_SHOP_DATABASE_PASSWORD:-}" ]; then
    sed -i "s|__MATOMO_SHOP_DB_PASSWORD__|${MATOMO_SHOP_DATABASE_PASSWORD}|g" "$INIT_SQL"
    echo "Injected Shop Matomo DB password into init.sql."
else
    echo "WARNING: MATOMO_SHOP_DATABASE_PASSWORD not set. init.sql NOT fully updated." >&2
fi
if [ -n "${MATOMO_WEB_DATABASE_PASSWORD:-}" ]; then
    sed -i "s|__MATOMO_WEB_DB_PASSWORD__|${MATOMO_WEB_DATABASE_PASSWORD}|g" "$INIT_SQL"
    echo "Injected Web Matomo DB password into init.sql."
else
    echo "WARNING: MATOMO_WEB_DATABASE_PASSWORD not set. init.sql NOT fully updated." >&2
fi

# ── SSH config for StorageBox ─────────────────────────────
echo "Setting up StorageBox SSH access..."
BACKUP_KEY="$INSTALL_DIR/config/backup/backup_key"

if [ ! -f "$BACKUP_KEY" ]; then
    echo ""
    echo "Backup SSH key not found at ${BACKUP_KEY}."
    echo "Please place the StorageBox SSH private key there."
    read -r -p "Press Enter after you've placed the key, or Ctrl-C to abort..."
fi

if [ -f "$BACKUP_KEY" ] && [ -n "${STORAGEBOX_HOST:-}" ]; then
    chmod 0600 "$BACKUP_KEY"
    chown deploy:deploy "$BACKUP_KEY"

    # SSH config for deploy user
    DEPLOY_SSH_DIR="/home/deploy/.ssh"
    mkdir -p "$DEPLOY_SSH_DIR"

    # Add StorageBox SSH config if not present
    if ! grep -q "Host storagebox" "$DEPLOY_SSH_DIR/config" 2>/dev/null; then
        cat >> "$DEPLOY_SSH_DIR/config" <<SSHCFG

Host storagebox
    HostName ${STORAGEBOX_HOST}
    User ${STORAGEBOX_USER}
    Port ${STORAGEBOX_PORT:-23}
    IdentityFile ${BACKUP_KEY}
    StrictHostKeyChecking accept-new
SSHCFG
        chmod 0600 "$DEPLOY_SSH_DIR/config"
    fi

    chown -R deploy:deploy "$DEPLOY_SSH_DIR"

    # Add StorageBox to known_hosts
    sudo -u deploy ssh-keyscan -p "${STORAGEBOX_PORT:-23}" "$STORAGEBOX_HOST" >> "$DEPLOY_SSH_DIR/known_hosts" 2>/dev/null || true
    echo "StorageBox SSH configured."
elif [ ! -f "$BACKUP_KEY" ]; then
    echo "WARNING: No backup key found. Restic backups will not work until configured." >&2
else
    echo "WARNING: STORAGEBOX_HOST not set in config.env. SSH config not created." >&2
fi

# ── Restic Repository Init ───────────────────────────────
echo "Checking Restic repository..."
if sudo -u deploy bash -c "source ${CONFIG_ENV} && export RESTIC_REPOSITORY RESTIC_PASSWORD && restic snapshots" &>/dev/null; then
    echo "Restic repository already initialized."
else
    echo "Initializing Restic repository..."
    sudo -u deploy bash -c "source ${CONFIG_ENV} && export RESTIC_REPOSITORY RESTIC_PASSWORD && restic init" || \
        echo "WARNING: Could not init Restic repo. Check backup_key and config.env." >&2
fi

echo ""
echo "=== Shared setup complete ==="
echo ""
echo "Next: run setup-caddy.sh, then setup-shop.sh / setup-mailcow.sh / setup-website.sh"
