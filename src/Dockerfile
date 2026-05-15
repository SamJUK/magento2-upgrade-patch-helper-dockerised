ARG PHP_VERSION=8.2
FROM php:${PHP_VERSION}-cli

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        unzip \
        libzip-dev \
        libicu-dev \
        libxml2-dev \
        libonig-dev \
    && docker-php-ext-install zip intl \
    && rm -rf /var/lib/apt/lists/*

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
