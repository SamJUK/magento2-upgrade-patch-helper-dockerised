ARG PHP_VERSION=8.2
FROM php:${PHP_VERSION}-cli-alpine

RUN apk add --no-cache \
        bash \
        git \
        unzip \
        libzip-dev \
        icu-dev \
        libxml2-dev \
        oniguruma-dev \
    && docker-php-ext-install zip intl

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

RUN git clone --depth=1 \
        https://github.com/AmpersandHQ/ampersand-magento2-upgrade-patch-helper \
        /patch-helper \
    && cd /patch-helper \
    && composer install --no-dev --no-interaction --no-scripts

WORKDIR /work

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
