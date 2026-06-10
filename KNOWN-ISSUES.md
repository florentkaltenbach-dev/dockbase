# Dockbase Known Issues

## CRITICAL — Must fix before migration

### 2. CrowdSec enrollment key location unknown

**Status:** Not started

The CrowdSec enrollment key and any bouncer API keys may not be in the current .env file. They might have been set interactively or stored in a CrowdSec config file inside the container.

**Fix:** On old server, run `docker exec dockbase_crowdsec cscli console status` and check CrowdSec config. Extract the key and add to config.env.

### 3. Backup script must dump both databases

**Status:** Not verified

The current backup.sh may only dump the shop database, not the matomo database.

**Fix:** Verify on old server. Update backup.sh to explicitly dump both `$MYSQL_DATABASE` and `matomo` databases with separate tags if needed.

## IMPORTANT — Address during migration

### 4. Matomo needs separate URL update

**Status:** Not started

`wp search-replace` only touches the WordPress database. Matomo stores its own site URL and trusted_hosts in config.ini.php and its database.

**Fix:** import.sh must include a step to:
1. Update `trusted_hosts[]` in Matomo's config.ini.php
2. Run SQL update on Matomo's `matomo_site` table to update the site URL

### 5. Docker daemon.json check

**Status:** Not verified

The old server may have custom Docker daemon configuration (log rotation, storage driver, default address pools) in /etc/docker/daemon.json.

**Fix:** Check on old server. If custom config exists, replicate in setup.sh.

## RESOLVED

### 1. Six plugins not managed by Composer (resolved 2026-04-25)

All eleven wpackagist-plugin entries in composer.json (including the six
previously volume-only plugins) now match composer.lock byte-for-byte. The
`plugins:` named volume was removed from docker-compose.yml; plugins are
baked into the image via `composer install` at build time. Audit results:
0 files in the old volume newer than the volume root, mtime-equal
composer.json/composer.lock, restic check 179 snapshots green.
Migration executed in the 2026-04-29 13:00 UTC maintenance window.
Rollback: /home/deploy/rollback-pre-issue3-2026-04-25.tar (374 MB,
sha256 7296bcb7…4668862) and dockbase-frankenphp:latest in image cache.

(Items move here when fixed, with date and resolution.)
