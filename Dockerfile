FROM richarvey/nginx-php-fpm:2.1.2
RUN apk add -U --no-cache nghttp2-dev nodejs npm  postgresql postgresql-dev
COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer
COPY . /var/www/html/

ENV SKIP_COMPOSER 0
ENV PHP_ERRORS_STDERR 1
ENV RUN_SCRIPTS 1
ENV REAL_IP_HEADER 1


# Laravel config
ENV APP_KEY base64:R+QG2UfUtR9sswBurkqPoviy25XANaKrV/i/xE8ulPU=
ENV APP_ENV production
ENV APP_DEBUG false
ENV LOG_CHANNEL stderr
ENV APP_URL 0.0.0.0


# Allow composer to run as root
ENV COMPOSER_ALLOW_SUPERUSER 1
ENV NODEJS_ALLOW_SUPERUSER 1
ENV NPM_ALLOW_SUPERUSER 1
ENV YARN_ALLOW_SUPERUSER 1
ENV NPX_ALLOW_SUPERUSER 1
RUN echo 'pm.max_children = 15' >> /usr/local/etc/php-fpm.d/zz-docker.conf && \
    echo 'pm.max_requests = 500' >> /usr/local/etc/php-fpm.d/zz-docker.conf
I t
RUN composer install && chmod -R 777 .
#RUN php artisan cache:clear && php artisan view:clear
#RUN php artisan migrate:refresh --seed
#RUN php artisan db:wipe --drop-types --force && php artisan migrate:install
#RUN php artisan migrate --force
#RUN php artisan db:seed --force
EXPOSE 82
