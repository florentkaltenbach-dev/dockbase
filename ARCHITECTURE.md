# Dockbase Architecture

## Overview

Dockbase is a WooCommerce shop deployed as a Docker Compose stack on a single Hetzner VPS running Ubuntu 24.04 LTS. The server is hardened at the OS level and exposes SSH (22), HTTP (80), and HTTPS (443).

## Network flow

```
Internet → :22  → sshd (pubkey only, no root login)
Internet → :80  → Docker → FrankenPHP (HTTP redirects, ACME HTTP-01 challenges)
Internet → :443 → Docker → FrankenPHP (HTTPS + HTTP/3 via QUIC)
```

### Port details

| Port | Protocol | Listener | Purpose |
|------|----------|----------|---------|
| 22/tcp | SSH | sshd | Remote access, pubkey auth only |
| 80/tcp | HTTP | Docker (FrankenPHP) | Redirect to HTTPS + ACME challenges |
| 443/tcp | HTTPS | Docker (FrankenPHP) | TLS via Caddy |
| 443/udp | QUIC | Docker (FrankenPHP) | HTTP/3 |

### UFW rules

- 22/tcp (SSH)
- 80/tcp (HTTP)
- 443/tcp (HTTPS)
- 443/udp (HTTP/3 QUIC)
- Default deny incoming

## Docker Compose services

### 1. FrankenPHP (Caddy + PHP + WordPress)

- Image: custom, built from Dockerfile
- PHP 8.3 with extensions: gd, imagick, redis, intl, opcache, zip
- Caddy serves HTTPS, reverse proxies matomo.$SITE_DOMAIN to Matomo container
- WP-CLI included for maintenance scripts
- All plugins installed by Composer at build time
- Domain configured via $SITE_DOMAIN environment variable
- TLS via ACME HTTP-01 (automatic on first request after DNS points to server)

### 2. MariaDB

- Hosts two databases: `$MYSQL_DATABASE` (WordPress) and `matomo`
- Healthcheck: `mariadmin ping`
- Data in named volume `mariadb_data`

### 3. KeyDB (Redis-compatible)

- WP object cache backend
- maxmemory 512mb, allkeys-lru eviction
- No persistence needed (cache only)

### 4. Matomo

- Web analytics, accessible at matomo.$SITE_DOMAIN
- Reverse proxied through Caddy (FrankenPHP container)
- Uses separate database in same MariaDB instance
- Config and processed reports in named volume `matomo_data`

### 5. CrowdSec

- Reads Caddy access logs from bind-mounted /opt/dockbase/logs/
- Enrollment key stored in config.env

### Internal connections

- FrankenPHP → MariaDB (TCP 3306)
- FrankenPHP → KeyDB (TCP 6379)
- Matomo → MariaDB (TCP 3306)
- CrowdSec reads /opt/dockbase/logs/ (bind mount, read-only)

## Volumes and bind mounts

### In git (fully portable)

- `web/app/themes/` — bind-mounted into FrankenPHP
- `web/app/mu-plugins/` — bind-mounted into FrankenPHP
- `web/.well-known/` — bind-mounted into FrankenPHP
- `config/caddy/Caddyfile` — bind-mounted into FrankenPHP
- `docker-compose.yml`, `Dockerfile` — infrastructure as code
- `infra/`, `scripts/`, `docs/` — tooling and documentation

### Built by Docker

- `plugins` (named volume) — all WordPress plugins installed by Composer at build time. Nothing lives only in this volume.

### Needs migration (from Restic backup)

- `web/app/uploads/` — ~6.6GB product images and media
- `web/app/languages/` — ~50MB translation files
- `mariadb_data` (named volume) — SQL dump of shop + matomo databases
- `matomo_data` (named volume) — Matomo config and processed reports

### Host-level

- `/opt/dockbase/logs/` — Caddy access/error logs, read by CrowdSec, logrotated daily

### Secrets (manual transfer)

- `config.env` — single file containing: DB credentials, WP salts, Restic password, CrowdSec enrollment key, SITE_DOMAIN, OLD_DOMAIN, TLS_EMAIL
- `config/backup/backup_key` — SSH ed25519 private key for Hetzner StorageBox (chmod 0600)

## Backup

### What gets backed up

| Tag | Content | Source |
|-----|---------|--------|
| db | SQL dump of shop + matomo databases | `docker exec` mariadump |
| uploads | web/app/uploads/ | Bind mount |
| languages | web/app/languages/ | Bind mount |
| matomo | matomo_data volume contents | `docker run --rm` tar export |

### Destination

Hetzner StorageBox via Restic over SSH (port 23). Single repository, tagged snapshots.

### Schedule

Daily at 04:30. Script waits for all containers healthy (5-minute timeout) before proceeding. Runs after WP auto-update (04:00) so backups capture post-update state.

### Restore

`infra/import.sh` restores from Restic. It brings up only MariaDB + KeyDB first, imports databases, then starts remaining services. Runs `wp search-replace` if OLD_DOMAIN differs from SITE_DOMAIN. Updates Matomo trusted_hosts and site URL separately.

## Scheduled tasks

| Time | Task | Script |
|------|------|--------|
| 03:00 | Unattended-upgrades reboot window | systemd (auto) |
| 04:00 | WP core + plugin + theme updates | /opt/dockbase/scripts/wp-update.sh |
| 04:30 | Restic backup to StorageBox | /opt/dockbase/config/backup/scripts/backup.sh |

## DNS

- `$SITE_DOMAIN` → A record → server IP
- `matomo.$SITE_DOMAIN` → A record → same server IP
- Caddy handles TLS for both via ACME HTTP-01

## Rollback

If the new server is broken after DNS cutover: point DNS A records back to the old server IP. The old server remains untouched and running throughout the migration process. This is the escape hatch — no script needed, just a DNS change.
