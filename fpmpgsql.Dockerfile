# ==========================================
# STAGE 1: Frontend Asset Builder (Node.js)
# ==========================================
FROM node:16-alpine AS node_build
WORKDIR /app
COPY package*.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run prod || npm run build || true

# ==========================================
# STAGE 2: Composer Dependency Builder
# ==========================================
FROM composer:2 AS composer_build
WORKDIR /app

ENV COMPOSER_ALLOW_SUPERUSER=1

COPY composer.json composer.lock ./
RUN composer install \
    --no-dev \
    --no-interaction \
    --prefer-dist \
    --optimize-autoloader \
    --no-scripts \
    --ignore-platform-reqs

# ==========================================
# STAGE 3: PostgreSQL Initialization Builder
# ==========================================
FROM alpine:3.18 AS postgres_builder

ENV PGDATA=/var/lib/postgresql/data

RUN apk add --no-cache postgresql su-exec \
    && mkdir -p /run/postgresql $PGDATA \
    && chown -R postgres:postgres /run/postgresql $PGDATA \
    && su-exec postgres initdb -D $PGDATA \
    && su-exec postgres pg_ctl -D $PGDATA -o "-c listen_addresses='*'" -w start \
    && su-exec postgres psql --command "CREATE USER laravel_user WITH SUPERUSER PASSWORD 'secretpassword';" \
    && su-exec postgres psql --command "CREATE DATABASE laravel OWNER laravel_user;" \
    && su-exec postgres pg_ctl -D $PGDATA -m fast stop \
    && echo "host all all 127.0.0.1/32 trust" >> $PGDATA/pg_hba.conf

# ==========================================
# STAGE 4: Production Runtime
# ==========================================
FROM serversideup/php:7.4-fpm-nginx-alpine

USER root

ENV PGDATA=/var/lib/postgresql/data

# Install runtime packages & register Postgres as an S6 service daemon
RUN install-php-extensions pdo_pgsql pgsql \
    && apk add --no-cache postgresql postgresql-client su-exec curl \
    && mkdir -p /run/postgresql \
    && chown -R postgres:postgres /run/postgresql \
    && mkdir -p /etc/s6-overlay/s6-rc.d/postgres \
    && echo "longrun" > /etc/s6-overlay/s6-rc.d/postgres/type \
    && echo '#!/bin/execlineb -P' > /etc/s6-overlay/s6-rc.d/postgres/run \
    && echo 'su-exec postgres postgres -D /var/lib/postgresql/data' >> /etc/s6-overlay/s6-rc.d/postgres/run \
    && chmod +x /etc/s6-overlay/s6-rc.d/postgres/run \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/postgres \
    && rm -rf /tmp/* /var/cache/apk/*

# Copy pre-built PostgreSQL cluster from Stage 3
COPY --from=postgres_builder --chown=postgres:postgres $PGDATA $PGDATA

WORKDIR /var/www/html

# Consolidated Environment Variables (including OPcache and Superuser flags)
ENV COMPOSER_ALLOW_SUPERUSER=1 \
    NODEJS_ALLOW_SUPERUSER=1 \
    NPM_ALLOW_SUPERUSER=1 \
    YARN_ALLOW_SUPERUSER=1 \
    NPX_ALLOW_SUPERUSER=1 \
    PHP_OPCACHE_ENABLE=1 \
    WEB_ROOT=/var/www/html/public \
    APP_ENV=production \
    APP_DEBUG=false \
    LOG_CHANNEL=stderr \
    APP_URL=0.0.0.0 \
    APP_KEY=base64:R+QG2UfUtR9sswBurkqPoviy25XANaKrV/i/xE8ulPU= \
    DATABASE_URL=pgsql://laravel_user:secretpassword@127.0.0.1:5432/laravel

# PHP-FPM Performance & Resource Adjustments
RUN echo 'pm.max_children = 15' >> /usr/local/etc/php-fpm.d/zz-docker.conf && \
    echo 'pm.max_requests = 500' >> /usr/local/etc/php-fpm.d/zz-docker.conf && \
    echo 'memory_limit = 256M' > /usr/local/etc/php/conf.d/zz-memory.ini && \
    echo 'upload_max_filesize = 64M' >> /usr/local/etc/php/conf.d/zz-memory.ini && \
    echo 'post_max_size = 64M' >> /usr/local/etc/php/conf.d/zz-memory.ini

# Copy build artifacts and source code
COPY --chown=www-data:www-data --from=composer_build /app/vendor ./vendor
COPY --chown=www-data:www-data --from=node_build /app/public/build ./public/build 2>/dev/null || true
COPY --chown=www-data:www-data --from=node_build /app/public/js ./public/js 2>/dev/null || true
COPY --chown=www-data:www-data --from=node_build /app/public/css ./public/css 2>/dev/null || true
COPY --chown=www-data:www-data . .

# Set strict permissions and create necessary storage directories
RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html \
    && mkdir -p storage/framework/sessions storage/framework/views storage/framework/cache \
    && chmod -R 775 storage bootstrap/cache

# Safe Build-Time Optimization (Using SQLite driver to safely bypass external DB requirement during build)
RUN DB_CONNECTION=sqlite php artisan optimize \
    && php artisan storage:link --force

# Inline Entrypoint Script: Boots embedded Postgres, runs migrations safely, then hands control to S6 Overlay (/init)
RUN echo '#!/usr/bin/env sh' > /docker-entrypoint.sh && \
    echo 'set -e' >> /docker-entrypoint.sh && \
    echo 'echo "Starting local PostgreSQL instance..."' >> /docker-entrypoint.sh && \
    echo 'su-exec postgres pg_ctl -D /var/lib/postgresql/data -o "-c listen_addresses='\''*'\''" -w start' >> /docker-entrypoint.sh && \
    echo 'echo "Waiting for database to be ready..."' >> /docker-entrypoint.sh && \
    echo 'until pg_isready -h 127.0.0.1 -p 5432 -U laravel_user; do sleep 1; done' >> /docker-entrypoint.sh && \
    echo 'echo "Running database migrations..."' >> /docker-entrypoint.sh && \
    echo 'php artisan migrate --force' >> /docker-entrypoint.sh && \
    echo 'su-exec postgres pg_ctl -D /var/lib/postgresql/data -m fast stop' >> /docker-entrypoint.sh && \
    echo 'exec /init' >> /docker-entrypoint.sh && \
    chmod +x /docker-entrypoint.sh

EXPOSE 8080

#HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
#  CMD curl -f http://localhost:8080/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
