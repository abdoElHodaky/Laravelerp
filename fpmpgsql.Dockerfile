# ==========================================
# STAGE 1: Composer Dependency Builder
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
# STAGE 2: PostgreSQL Initialization Builder
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
# STAGE 3: Production Runtime
# ==========================================
FROM serversideup/php:7.4-fpm-nginx-alpine

USER root

# Unified Runtime Package Installation & S6 Service Registration
ENV PGDATA=/var/lib/postgresql/data

RUN install-php-extensions pdo_pgsql pgsql \
    && apk add --no-cache postgresql postgresql-client su-exec \
    && mkdir -p /run/postgresql \
    && chown -R postgres:postgres /run/postgresql \
    # Register PostgreSQL as a managed S6 longrun daemon
    && mkdir -p /etc/s6-overlay/s6-rc.d/postgres \
    && echo "longrun" > /etc/s6-overlay/s6-rc.d/postgres/type \
    && echo '#!/bin/execlineb -P' > /etc/s6-overlay/s6-rc.d/postgres/run \
    && echo 'su-exec postgres postgres -D /var/lib/postgresql/data' >> /etc/s6-overlay/s6-rc.d/postgres/run \
    && chmod +x /etc/s6-overlay/s6-rc.d/postgres/run \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/postgres \
    && rm -rf /tmp/* /var/cache/apk/*

# Copy pre-built PostgreSQL cluster from Stage 2
COPY --from=postgres_builder --chown=postgres:postgres $PGDATA $PGDATA

WORKDIR /var/www/html

# Consolidated Environment Variables
ENV COMPOSER_ALLOW_SUPERUSER=1 \
    NODEJS_ALLOW_SUPERUSER=1 \
    NPM_ALLOW_SUPERUSER=1 \
    YARN_ALLOW_SUPERUSER=1 \
    NPX_ALLOW_SUPERUSER=1 \
    WEB_ROOT=/var/www/html/public \
    APP_ENV=production \
    APP_DEBUG=false \
    LOG_CHANNEL=stderr \
    APP_URL=0.0.0.0 \
    APP_KEY=base64:R+QG2UfUtR9sswBurkqPoviy25XANaKrV/i/xE8ulPU= \
    DB_CONNECTION=pgsql \
    DB_HOST=127.0.0.1 \
    DB_PORT=5432 \
    DB_DATABASE=laravel \
    DB_USERNAME=laravel_user \
    DB_PASSWORD=secretpassword

# Configure PHP-FPM pool settings
RUN echo 'pm.max_children = 15' >> /usr/local/etc/php-fpm.d/zz-docker.conf && \
    echo 'pm.max_requests = 500' >> /usr/local/etc/php-fpm.d/zz-docker.conf

# Copy application files and vendor dependencies in correct order
COPY --chown=www-data:www-data --from=composer_build /app/vendor ./vendor
COPY --chown=www-data:www-data . .

# Apply requested permissions
RUN chmod -R 777 .

# Artisan build hooks (uncomment if required)
# RUN php artisan cache:clear && php artisan view:clear
# RUN php artisan migrate:refresh --seed
# RUN php artisan db:wipe --drop-types --force && php artisan migrate:install
# RUN php artisan migrate --force
# RUN php artisan db:seed --force

EXPOSE 8080
