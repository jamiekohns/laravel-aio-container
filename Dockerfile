# Laravel PHP 8.3 FPM + Nginx Dockerfile Laravel-php83-fpm-nginx
FROM php:8.3-fpm-bookworm

ARG UID=1000
ARG GID=1000

ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_HOME=/tmp/composer

# System deps + PHP extension build deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl unzip ca-certificates nginx subversion \
    nodejs npm nano sudo ripgrep \
    libzip-dev libicu-dev libonig-dev libxml2-dev \
    libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
    libldap2-dev \
    libpq-dev libsqlite3-dev \
    tree tmux locales procps gnupg2 unixodbc-dev build-essential gpg \
    && rm -rf /var/lib/apt/lists/*

# PHP extensions commonly needed by Laravel
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
    pdo_mysql mbstring exif pcntl bcmath gd intl zip ldap

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Node Version Manager (NVM) + default Node runtime
ARG NODE_VERSION=20
ENV NVM_DIR=/usr/local/nvm
RUN mkdir -p "$NVM_DIR" \
    && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh -o /tmp/install_nvm.sh \
    && PROFILE=/dev/null bash /tmp/install_nvm.sh \
    && rm -f /tmp/install_nvm.sh \
    && bash -lc '. "$NVM_DIR/nvm.sh" \
        && nvm install "$NODE_VERSION" \
        && nvm alias default "$NODE_VERSION" \
        && nvm use default \
        && NODE_BIN_DIR="$(dirname "$(nvm which default)")" \
        && ln -sf "$NODE_BIN_DIR/node" /usr/local/bin/node \
        && ln -sf "$NODE_BIN_DIR/npm" /usr/local/bin/npm \
        && ln -sf "$NODE_BIN_DIR/npx" /usr/local/bin/npx'

# Microsoft SQL Server support
RUN curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg && \
    gpg --keyserver keyserver.ubuntu.com --recv-keys EE4D7792F748182B && \
    gpg --export EE4D7792F748182B | tee -a /usr/share/keyrings/microsoft-prod.gpg > /dev/null && \
    curl https://packages.microsoft.com/config/debian/12/prod.list | tee /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install -y msodbcsql18 && \
    rm -rf /var/lib/apt/lists/*

# PECL + SQLSRV
RUN curl -O https://pear.php.net/go-pear.phar && \
    printf "\n" | php go-pear.phar && \
    rm go-pear.phar && \
    pecl channel-update pecl.php.net

RUN pecl install sqlsrv pdo_sqlsrv && \
    echo "extension=sqlsrv.so" > /usr/local/etc/php/conf.d/20-sqlsrv.ini && \
    echo "extension=pdo_sqlsrv.so" > /usr/local/etc/php/conf.d/30-pdo_sqlsrv.ini

# Optional mailparse
ARG INSTALL_MAILPARSE
RUN if [ "$INSTALL_MAILPARSE" = "true" ] ; then \
    pecl install mailparse && docker-php-ext-enable mailparse ; \
fi

# Align www-data UID/GID with host user for local development
RUN groupmod -o -g ${GID} www-data \
    && usermod -o -u ${UID} -g www-data www-data

# Create dev user with www-data as primary group for interactive shell access
RUN useradd -m -s /bin/bash -g www-data dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

# Copy .bashrc and scripts for dev user
COPY bash/.bashrc /home/dev/.bashrc
COPY bash/scripts /home/dev/scripts
RUN chown -R dev:www-data /home/dev && chmod -R 755 /home/dev/scripts

WORKDIR /var/www/html
RUN chown www-data:www-data /var/www/html && chmod 775 /var/www/html

# Nginx site + container startup
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf.default || true

EXPOSE 80
CMD ["/usr/local/bin/entrypoint.sh"]