#!/usr/bin/env sh
set -eu

# Ensure the webroot is owned by www-data (handles bind-mounted volumes)
chown -R www-data:www-data /var/www/html
# g+rwX: grants group read/write; capital X sets execute only on dirs and already-executable files
chmod -R g+rwX /var/www/html
# Explicitly restore execute bits on node_modules binaries (bind-mounts may strip them)
[ -d /var/www/html/node_modules/.bin ] && find /var/www/html/node_modules/.bin -exec chmod a+x {} + 2>/dev/null || true

# Ensure Laravel storage and cache directories exist
mkdir -p \
    /var/www/html/storage/app/public \
    /var/www/html/storage/framework/cache/data \
    /var/www/html/storage/framework/sessions \
    /var/www/html/storage/framework/views \
    /var/www/html/storage/logs \
    /var/www/html/bootstrap/cache

chown -R www-data:www-data \
    /var/www/html/storage \
    /var/www/html/bootstrap/cache

chmod -R 775 \
    /var/www/html/storage \
    /var/www/html/bootstrap/cache

mkdir -p /run/php

# Start PHP-FPM in the background, then keep Nginx in the foreground.
php-fpm -D
exec nginx -g 'daemon off;'
