# syntax=docker/dockerfile:1.3

FROM php:8.4-fpm-alpine3.24
RUN set -ex; \
    \
    # Refuse to build on a PHP release vulnerable to CVE-2026-109618 / CVE-2026-109619 (PHP2Shell)
    php -r 'exit(version_compare(PHP_VERSION, "8.4.27", ">=") ? 0 : 1);' || { \
        echo "PHP $(php -r 'echo PHP_VERSION;') is vulnerable, 8.4.27 or later is required" >&2; \
        exit 1; \
    }; \
    \
    export CFLAGS="${PHP_CFLAGS:?}"; \
    export CPPFLAGS="${PHP_CPPFLAGS:?}"; \
    export LDFLAGS="${PHP_LDFLAGS:?} -Wl,--strip-all"; \
    \
    # Runtime dependencies
    apk add --no-cache \
        icu \
        libintl \
        libpng \
        libzip \
        msmtp \
        nginx \
        openldap \
        runit \
    ; \
    \
    # Build dependencies
    apk add --no-cache --virtual .build-deps \
        ${PHPIZE_DEPS} \
        gettext-dev \
        icu-dev \
        libpng-dev \
        libzip-dev \
        linux-headers \
        openldap-dev \
    ; \
    \
    # Install PHP extensions (imap was unbundled from PHP 8.4; osTicket 1.18 fetches mail via the
    # bundled Laminas Mail library and only lists imap as optional)
    docker-php-ext-install -j "$(nproc)" \
        gd \
        gettext \
        intl \
        ldap \
        mysqli \
        sockets \
        zip \
    ; \
    pecl install apcu; \
    docker-php-ext-enable \
        apcu \
        opcache \
    ; \
    \
    # Create msmtp log
    touch /var/log/msmtp.log; \
    chown www-data:www-data /var/log/msmtp.log; \
    \
    # Create data dir
    mkdir /var/lib/osticket; \
    \
    # Clean up
    apk del .build-deps; \
    rm -rf /tmp/pear /var/cache/apk/*
# DO NOT FORGET TO CHECK THE LANGUAGE PACK DOWNLOAD URL BELOW
# DO NOT FORGET TO UPDATE "image-version" FILE
ENV OSTICKET_VERSION=1.18.4 \
    OSTICKET_SHA256SUM=a4187df5f52dd41625e6b61b322245853542e12b5969a45f0a6d81f7ab8151a7
RUN --mount=type=bind,source=utils/verify-plugin.php,target=/tmp/verify-plugin.php,readonly \
    \
    set -ex; \
    \
    wget -q -O osTicket.zip https://github.com/osTicket/osTicket/releases/download/\
v${OSTICKET_VERSION}/osTicket-v${OSTICKET_VERSION}.zip; \
    echo "${OSTICKET_SHA256SUM}  osTicket.zip" | sha256sum -c; \
    unzip osTicket.zip 'upload/*'; \
    rm osTicket.zip; \
    mkdir /usr/local/src; \
    mv upload /usr/local/src/osticket; \
    # Hard link the sources to the public directory
    cp -al /usr/local/src/osticket/. /var/www/html; \
    # Hide setup
    rm -r /var/www/html/setup; \
    \
    cd /var/www/html; \
    \
    for lang in bg bn bs ca cs da de el es_AR es_ES es_MX et eu fa fi fr gl he hi hr hu id is it \
        ja ka km ko lt lv mk mn ms nl no pl pt_BR pt_PT ro ru sk sl sq sr sr_CS sv_SE sw th tr uk \
        ur_IN ur_PK vi zh_CN zh_TW; do \
        # Packs for the current minor version are preferred. Some (e.g. pt_BR) have not been
        # published for 1.18.x yet, so fall back to the previous minor version for those.
        wget -q -O /var/www/html/include/i18n/${lang}.phar \
            https://s3.amazonaws.com/downloads.osticket.com/lang/1.18.x/${lang}.phar \
        || wget -q -O /var/www/html/include/i18n/${lang}.phar \
            https://s3.amazonaws.com/downloads.osticket.com/lang/1.17.x/${lang}.phar; \
        php /tmp/verify-plugin.php "/var/www/html/include/i18n/${lang}.phar"; \
    done
RUN set -ex; \
    \
    for plugin in audit auth-2fa auth-ldap auth-oauth2 auth-passthru auth-password-policy \
        storage-fs storage-s3; do \
        wget -q -O /var/www/html/include/plugins/${plugin}.phar \
            https://s3.amazonaws.com/downloads.osticket.com/plugin/${plugin}.phar; \
    done; \
    # This checks `.phar` integrity (authenticity check is not supported - see
    # https://github.com/osTicket/osTicket/issues/6376).
    for phar in /var/www/html/include/plugins/*.phar; do \
        # The following PHP code throws an exception and returns non-zero if .phar can't be loaded
        # (e.g. due to a checksum mismatch)
        php -r "new Phar(\"${phar}\");"; \
    done
ENV OSTICKET_SLACK_VERSION=de1d9a276a64520eea6e6368e609a0f4c4829d96 \
    OSTICKET_SLACK_SHA256SUM=8d06500fd5b8a589a5f7103c242160086ca1696a5b93d0e3767119a54059532b
RUN set -ex; \
    \
    wget -q -O osTicket-slack-plugin.tar.gz https://github.com/devinsolutions/\
osTicket-slack-plugin/archive/${OSTICKET_SLACK_VERSION}.tar.gz; \
    echo "${OSTICKET_SLACK_SHA256SUM}  osTicket-slack-plugin.tar.gz" | sha256sum -c; \
    tar -xzf osTicket-slack-plugin.tar.gz -C /var/www/html/include/plugins --strip-components 1 \
        osTicket-slack-plugin-${OSTICKET_SLACK_VERSION}/slack; \
    rm osTicket-slack-plugin.tar.gz
COPY root /
CMD ["start"]
STOPSIGNAL SIGTERM
EXPOSE 80
HEALTHCHECK CMD curl -fIsS http://localhost/ || exit 1
