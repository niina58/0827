FROM php:8.4-fpm-alpine AS php
 
RUN docker-php-ext-install pdo_mysql
 
RUN install -o www-data -g www-data -d /var/www/upload/image/
 
RUN docker-php-ext-install fileinfo && docker-php-ext-enable fileinfo
 
COPY uploads.ini /usr/local/etc/php/conf.d/uploads.ini
