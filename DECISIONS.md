# Dockbase Decisions Log

Format: date, decision, reasoning, status.

## 2026-04-25: Remove the `plugins` named volume

**Decision:** Remove `plugins:/app/web/app/plugins` mount and the top-level
`plugins:` volume from docker-compose.yml. Plugins are baked into the image
via `composer install` at build time and owned by www-data through a single
`chown -R www-data:www-data /app/web` line in the Dockerfile.
**Reasoning:** Audit on 2026-04-25 confirmed all 11 wpackagist-plugin entries
match composer.lock byte-for-byte, no runtime writes in the volume (0 files
newer than the volume root), and composer.json/composer.lock mtimes equal.
The volume only hid drift and complicated rollback. Build dry-run
(--no-cache) measured 3m11s with 6.1s composer install and 0.4s chown, so
the maintenance-window cost is well under the single-hour 13:00 UTC trough.
wp-update.sh is intentionally untouched here — silent failure inside it is
no worse than today, and a proper update pipeline is deferred to a follow-
up project gated on the monitoring stack.
**Status:** Staged on branch `issue-3-plugins-volume-removal`; merge during
maintenance window 2026-04-29 13:00 UTC.

**Migration sequence (from /opt/dockbase as deploy):**

    git checkout main && git pull --ff-only
    docker compose down
    docker volume rm dockbase_plugins
    docker compose build
    docker compose up -d
    sleep 30 && docker compose ps
    curl -fsS -o /dev/null -w '%{http_code}\n' "https://${SITE_DOMAIN}/"

Expect: all services Up (healthy), HTTP 200. Mailcow is a separate compose
project at /opt/mailcow and is unaffected.

**Rollback (if smoke fails) — primary path is the tarball, deterministic:**

    docker compose down
    docker load -i /home/deploy/rollback-pre-issue3-2026-04-25.tar
    docker compose up -d

Tarball: 374 MB, sha256
7296bcb734efa4d6eb8eac92e5c8bdbd5cf081a1f7e0bdb96d093b53e4668862.

## 2026-03-17: Clean fixes only

**Decision:** All infrastructure problems are fixed properly, no workarounds.
**Reasoning:** The whole point of the migration is to make the project portable. Quick fixes (volume dumps, manual plugin installs) undermine that goal.
**Status:** Active

## 2026-03-17: Add all 6 unmanaged plugins to Composer

**Decision:** WP-Piwik, Google Listings & Ads, Pinterest for WooCommerce, TikTok for Business, WooCommerce PayPal, and WooCommerce Services must be added to composer.json.
**Reasoning:** These plugins lived only in a Docker named volume. A fresh `docker compose build` would lose them. Composer management makes them reproducible.
**Status:** Resolved 2026-04-25 (see 2026-04-25 entry above; volume removal closes the loop).

## 2026-03-17: Full Matomo migration

**Decision:** Migrate Matomo with full analytics history, not a fresh install.
**Reasoning:** Proves the entire stack migrates cleanly. Analytics history has business value.
**Status:** Not started

## 2026-03-17: Drop PeterPC restic-sync

**Decision:** Remove the restic-sync service, systemd timer, .restic-sync.env, and all related files.
**Reasoning:** Not needed on the new server. Simplifies backup architecture to a single direction: server → StorageBox.
**Status:** Not started

## 2026-03-17: KeyDB maxmemory 512mb

**Decision:** Keep the production value of 512mb, not the 256mb that appeared in early documentation.
**Reasoning:** WooCommerce is cache-hungry (products, variations, pricing, cart fragments, API transients). On a 4GB server, 512mb for Redis is the right balance. 256mb would cause premature eviction and more DB queries under load.
**Status:** Active

## 2026-03-17: Single config.env with .env symlink

**Decision:** All secrets and site config live in config.env. A .env symlink points to it for Docker Compose parse-time interpolation. Both are git-ignored.
**Reasoning:** Docker Compose auto-loads .env for ${VAR} interpolation in docker-compose.yml. Renaming to config.env gives a clearer developer experience ("this is the one config file") while the symlink preserves Compose compatibility.
**Status:** Not started

## 2026-03-17: Staggered maintenance schedule

**Decision:** Reboot window at 03:00, WP update at 04:00, backup at 04:30.
**Reasoning:** If unattended-upgrades triggers a kernel reboot at 03:00, the server has 60 minutes to come back up before WP update runs. Backup runs after WP update to capture post-update state. Backup script includes a healthcheck gate (5-min timeout) as safety net.
**Status:** Not started

## 2026-03-17: Restore ordering — DB first, then app

**Decision:** import.sh brings up only MariaDB + KeyDB, restores databases, then starts FrankenPHP + Matomo + CrowdSec.
**Reasoning:** If WordPress containers start against an empty database, WP may run its installer and create default tables before import finishes, causing conflicts.
**Status:** Not started

## 2026-03-17: WordPress search-replace is a platform constraint

**Decision:** URLs are config-driven via config.env for application config, but database content requires a one-time `wp search-replace` at import. Matomo needs a separate URL update.
**Reasoning:** WordPress and WooCommerce store absolute URLs in the database (post content, serialized meta, widget config). WP-CLI's search-replace handles serialized PHP data correctly. Matomo has its own trusted_hosts and site URL config that WordPress tools don't touch.
**Status:** Not started

## 2026-03-17: Public GitHub repo

**Decision:** The dockbase template repo is public. Bootstrap scripts are curl-able from raw.githubusercontent.com.
**Reasoning:** Enables one-click setup on a fresh server without needing deploy keys or tokens for the initial clone. Secrets are never committed — they live in config.env (git-ignored).
**Status:** Not started

## 2026-03-17: Rollback plan

**Decision:** If the new server fails after DNS cutover, point DNS back to the old server IP. No automated rollback script.
**Reasoning:** The old server stays untouched throughout migration. DNS change is the simplest and most reliable rollback mechanism. TTL should be lowered before cutover to speed up propagation if rollback is needed.
**Status:** Documented
