ARG PHP_VERSION=8.2
# Builds pass the pinned image from php/<minor>/Dockerfile, which Dependabot bumps
ARG PHP_IMAGE=php:${PHP_VERSION}-cli-alpine
# Fork with fixes and new checks not yet merged upstream (idhlagency/ampersand-magento2-upgrade-patch-helper).
# Declared globally so the final stage can label the image with them.
ARG PATCH_HELPER_REPO=https://github.com/convenient/convenient-magento2-upgrade-patch-helper.git
ARG PATCH_HELPER_REF=26304333518b46e36577e920f7d7294098038ae9

FROM composer:2.11.2@sha256:0c8e663f14c94d07b3c45b175c51f5a14718508f21fe4dd7e54f09488dd0ed71 AS composer

FROM ${PHP_IMAGE} AS build
COPY --from=composer /usr/bin/composer /usr/bin/composer
RUN apk add --no-cache git

ARG PATCH_HELPER_REPO
ARG PATCH_HELPER_REF
RUN git init -q /patch-helper \
    && git -C /patch-helper fetch -q --depth=1 "$PATCH_HELPER_REPO" "$PATCH_HELPER_REF" \
    && git -C /patch-helper checkout -q FETCH_HEAD \
    && composer install -d /patch-helper --no-dev --no-interaction --no-progress --optimize-autoloader \
    && rm -rf /patch-helper/.git /patch-helper/dev /patch-helper/.github

FROM ${PHP_IMAGE} AS runtime

# patch and diffutils: patch-helper needs GNU patch, and busybox diff output differs from GNU diff -urN
# The rm drops the PHP source, headers and SAPIs a CLI tool never uses (about 50MB)
RUN apk add --no-cache bash diffutils git patch su-exec tini unzip \
    && rm -rf /usr/src/* /usr/local/include /usr/local/php /usr/local/lib/php/build \
        /usr/local/bin/php-cgi /usr/local/bin/phpdbg /usr/local/bin/phpize /usr/local/bin/php-config \
        /usr/local/bin/docker-php-* /var/cache/apk/* \
    && git config --system safe.directory '*' \
    && chmod 755 /root \
    && mkdir -m 1777 /root/.composer

COPY --from=composer /usr/bin/composer /usr/bin/composer
COPY --from=build /patch-helper /patch-helper
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Flatten so the files removed above are not kept in base image layers
FROM scratch
COPY --from=runtime / /

ARG PATCH_HELPER_REPO
ARG PATCH_HELPER_REF
LABEL org.opencontainers.image.title="magento2-upgrade-patch-helper" \
      org.opencontainers.image.source="https://github.com/SamJUK/magento2-upgrade-patch-helper-dockerised" \
      org.opencontainers.image.licenses="MIT AND LGPL-3.0-only" \
      io.github.patch-helper.repo="${PATCH_HELPER_REPO}" \
      io.github.patch-helper.ref="${PATCH_HELPER_REF}"

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    COMPOSER_HOME=/root/.composer \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1

ENTRYPOINT ["/sbin/tini", "-g", "--", "/entrypoint.sh"]
