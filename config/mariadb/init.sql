-- Dockbase MariaDB initialization
-- WordPress database is created automatically via MYSQL_DATABASE env var.

-- Shop Matomo database and user
CREATE DATABASE IF NOT EXISTS matomo_shop CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'matomo_shop'@'%' IDENTIFIED BY '__MATOMO_SHOP_DB_PASSWORD__';
GRANT ALL PRIVILEGES ON matomo_shop.* TO 'matomo_shop'@'%';

-- Web Matomo database and user
CREATE DATABASE IF NOT EXISTS matomo_web CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'matomo_web'@'%' IDENTIFIED BY '__MATOMO_WEB_DB_PASSWORD__';
GRANT ALL PRIVILEGES ON matomo_web.* TO 'matomo_web'@'%';

-- Legacy: keep 'matomo' database for migration compatibility
-- Old backups reference this name; import.sh handles the rename.
CREATE DATABASE IF NOT EXISTS matomo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'matomo'@'%' IDENTIFIED BY '__MATOMO_SHOP_DB_PASSWORD__';
GRANT ALL PRIVILEGES ON matomo.* TO 'matomo'@'%';

FLUSH PRIVILEGES;
