# Built by .github/workflows/deploy.yml (context ., file Dockerfile) and pushed
# to Artifact Registry.
#
# Yii 2 basic app on FrankenPHP (a Caddy-based PHP app server): docroot web/,
# YII_ENV=prod, served on 0.0.0.0:$PORT with the PORT read from the environment
# when the container STARTS.
FROM dunglas/frankenphp:1-php8.4-bookworm AS runtime
RUN install-php-extensions intl pdo_pgsql zip
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-interaction
COPY . .
RUN composer dump-autoload --optimize --no-dev --no-interaction \
 && useradd -r -u 10001 -d /app app \
 && mkdir -p runtime web/assets && chown -R app:app runtime web/assets /config/caddy /data/caddy
# KEEP THIS: one log line per request (status + duration) is what the workspace Monitoring tab charts.
# docker/request-log.caddyfile turns on Caddy's JSON access log on stdout; the stock Caddyfile
# imports it into its site block through CADDY_SERVER_EXTRA_DIRECTIVES.
COPY docker/request-log.caddyfile /etc/frankenphp/request-log.caddyfile
ENV CADDY_SERVER_EXTRA_DIRECTIVES="import /etc/frankenphp/request-log.caddyfile"
ARG BUILD_ID=""
ENV PORT=8080 SERVER_ROOT=/app/web YII_ENV=prod YII_DEBUG=false BUILD_ID=$BUILD_ID
USER app
EXPOSE 8080
CMD ["sh", "-c", "SERVER_NAME=\":${PORT}\" exec frankenphp run --config /etc/frankenphp/Caddyfile"]
