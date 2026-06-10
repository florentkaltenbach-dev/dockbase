# Dockbase Secrets Inventory

Every secret needed for the deployment. Transfer status tracks migration progress.

## config.env (the single secrets file)

| Variable | Description | Source | Transfer status |
|----------|-------------|--------|-----------------|
| SITE_DOMAIN | New site domain | New server setup | ☐ Set for new server |
| OLD_DOMAIN | Previous domain (migration only) | Old server .env | ☐ Copy from old server |
| TLS_EMAIL | Email for Let's Encrypt ACME | Operator choice | ☐ Set for new server |
| MYSQL_ROOT_PASSWORD | MariaDB root password | Old server .env | ☐ Copy from old server |
| MYSQL_PASSWORD | MariaDB WordPress user password | Old server .env | ☐ Copy from old server |
| MATOMO_DATABASE_PASSWORD | MariaDB Matomo user password | Old server .env | ☐ Copy from old server |
| AUTH_KEY | WP salt | Old server .env | ☐ Copy from old server |
| SECURE_AUTH_KEY | WP salt | Old server .env | ☐ Copy from old server |
| LOGGED_IN_KEY | WP salt | Old server .env | ☐ Copy from old server |
| NONCE_KEY | WP salt | Old server .env | ☐ Copy from old server |
| AUTH_SALT | WP salt | Old server .env | ☐ Copy from old server |
| SECURE_AUTH_SALT | WP salt | Old server .env | ☐ Copy from old server |
| LOGGED_IN_SALT | WP salt | Old server .env | ☐ Copy from old server |
| NONCE_SALT | WP salt | Old server .env | ☐ Copy from old server |
| RESTIC_REPOSITORY | Restic repo path on StorageBox | Old server .env | ☐ Copy from old server |
| RESTIC_PASSWORD | Restic encryption password | Old server .env | ☐ Copy from old server |
| CROWDSEC_ENROLL_KEY | CrowdSec console enrollment | Old server (find location) | ☐ Extract from old server |
| WP_SMTP_HOST | Mailcow submission hostname (TLS CN match) | mail.shop.example.com | ☐ Default in config.env.example |
| WP_SMTP_USER | Real mailbox auth user (aliases can't auth) | info@shop.example.com | ☐ Provisioned by setup-mailcow.sh |
| WP_SMTP_PASS | Mailbox password | /opt/mailcow/initial-passwords.txt on server | ☐ Auto-pulled by setup helpers |
| WP_SMTP_FROM_EMAIL | "From" address WC uses | orders@shop.example.com | ☐ Default in config.env.example |

## SSH keys

| File | Description | Source | Transfer status |
|------|-------------|--------|-----------------|
| config/backup/backup_key | Ed25519 private key for StorageBox | Old server /opt/dockbase/config/backup/backup_key | ☐ Copy (chmod 0600) |
| ~deploy/.ssh/authorized_keys | Your SSH public key(s) | Your local machine | ☐ Place during harden.sh |

## SSH config (created by setup.sh)

| File | Content | Created by |
|------|---------|------------|
| ~deploy/.ssh/config | Host storagebox alias → uXXXXXX.your-storagebox.de:23 using backup_key | setup.sh |
| /root/.ssh/config | Same (root runs backup cron) | setup.sh |
| ~deploy/.ssh/known_hosts | StorageBox host key | setup.sh (ssh-keyscan) |
| /root/.ssh/known_hosts | StorageBox host key | setup.sh (ssh-keyscan) |

## CrowdSec keys — action needed

The CrowdSec enrollment key may not be in the current .env file. Before migration:

1. On old server: `docker exec dockbase_crowdsec cscli console status`
2. Check if the enrollment key is stored in a CrowdSec config file inside the container
3. If found, add it to config.env as CROWDSEC_ENROLL_KEY
4. If not recoverable, register a new enrollment via the CrowdSec console

## Notes

- config.env is git-ignored. config.env.example is the committed template.
- .env is a symlink to config.env (for Docker Compose parse-time interpolation). Also git-ignored.
- Never commit secrets. The public repo must contain zero real credentials.
