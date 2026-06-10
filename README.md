# Dockbase

A reusable WooCommerce shop stack running on Docker — FrankenPHP (Caddy + PHP), MariaDB, Redis, Matomo, and CrowdSec. Designed for one-click deployment to a fresh Ubuntu 24.04 server.

## Quick start

On a fresh Ubuntu 24.04 server (tested on Hetzner), SSH in as root and run:

```bash
# Phase 1: Harden the server
curl -sSL https://raw.githubusercontent.com/florentkaltenbach-dev/dockbase/main/infra/harden.sh | bash
reboot
```

Reconnect as `deploy` (the script creates this user and copies your SSH keys):

```bash
# Phase 2: Install Docker and deploy the stack
sudo bash -c 'curl -sSL https://raw.githubusercontent.com/florentkaltenbach-dev/dockbase/main/infra/setup.sh | bash'
```

The script will pause and ask you to place two files:

1. **`/opt/dockbase/config.env`** — copy from `config.env.example` and fill in real values
2. **`/opt/dockbase/config/backup/backup_key`** — your StorageBox SSH private key (chmod 0600)

Then import data from a Restic backup:

```bash
cd /opt/dockbase && sudo bash infra/import.sh
```

Point your DNS A records to the server IP and the site is live.

## What the scripts do

### `infra/harden.sh` (Phase 1 — run as root)

- Creates `deploy` user with sudo, copies root's SSH keys
- Hardens SSH: pubkey only, no root login
- Configures UFW: ports 22, 80, 443/tcp, 443/udp
- Installs fail2ban with sshd jail
- Applies sysctl security hardening
- Creates 2GB swap
- Configures unattended security upgrades (auto-reboot at 03:00)
- Sets up logrotate for application logs

### `infra/setup.sh` (Phase 2 — run as root)

- Installs Docker CE, Compose, Buildx
- Installs restic, git, rsync
- Clones this repo to `/opt/dockbase/`
- Creates `.env` symlink → `config.env`
- Sets up StorageBox SSH config and known_hosts
- Builds and starts all 5 Docker services
- Installs cron jobs: WP auto-update (04:00), backup (04:30)

### `infra/import.sh` (Phase 2b — data restore)

- Restores uploads, languages, databases, and Matomo data from Restic
- Runs `wp search-replace` if the domain has changed (reads `OLD_DOMAIN` from config.env)
- Updates Matomo site URL and trusted hosts
- Verifies all services are healthy

## Architecture

```
Internet → :22  → sshd (pubkey only)
Internet → :80  → Docker → Caddy/FrankenPHP (HTTP redirect + ACME)
Internet → :443 → Docker → Caddy/FrankenPHP (HTTPS + HTTP/3 QUIC)
```

Five Docker services: FrankenPHP (Caddy + PHP + WordPress), MariaDB (two databases: shop + analytics), Redis (object cache, 512mb), Matomo (analytics), CrowdSec (security monitoring).

All plugins are installed via Composer at build time. Nothing lives only in a Docker volume.

## Configuration

All secrets and site-specific config live in a single file: `config.env`. See `config.env.example` for the template. This file is git-ignored and never committed.

Docker Compose reads variables from `.env`, which is a symlink to `config.env`.

## Backup

Daily at 04:30 via Restic to Hetzner StorageBox. Four tagged snapshots:

| Tag | Content |
|-----|---------|
| db | SQL dump of shop + analytics databases |
| uploads | Product images and media (~6.6GB) |
| languages | Translation files (~50MB) |
| matomo | Analytics config and processed reports |

## Scheduled tasks

| Time | Task |
|------|------|
| 03:00 | Unattended-upgrades reboot window |
| 04:00 | WordPress core + plugin + theme updates |
| 04:30 | Restic backup to StorageBox |

## Migration

If migrating to a new server: run a fresh backup on the old server, spin up a new Ubuntu box, run the three scripts above. The old server stays untouched — if anything goes wrong, point DNS back.

See `docs/migration/` for detailed plans, decisions, and checklists.

## Documentation

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Project memory for Claude Code sessions |
| `config.env.example` | Template for all secrets and config |
| `docs/migration/ARCHITECTURE.md` | Infrastructure diagram in prose |
| `docs/migration/DECISIONS.md` | Every decision with reasoning |
| `docs/migration/MIGRATION-PLAN.md` | Phased checklist with status |
| `docs/migration/KNOWN-ISSUES.md` | Blockers and fixes |
| `docs/migration/SECRETS-INVENTORY.md` | Every secret and transfer status |
