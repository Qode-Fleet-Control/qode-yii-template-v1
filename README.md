# Yii template

Provisioned from [`Qode-Fleet-Control/fleet-template-v1`](https://github.com/Qode-Fleet-Control/fleet-template-v1) — the fleet
lifecycle contract (`bin/`, `fleet.conf`, `compose.yaml`, deploy workflows) with the
official Yii 2 Basic Project Template laid on top, served by FrankenPHP.

## Origin

    docker run --rm -u $(id -u):$(id -g) -v "$PWD":/w -w /w <php8.4 + composer:2 image> \
      composer create-project yiisoft/yii2-app-basic qode-yii-template-v1 --prefer-dist --no-interaction

Generated 2026-10-05 (yiisoft/yii2-app-basic, yiisoft/yii2 ~2.0.54, PHP 8.4.26 — the PHP
the image runs). `vendor/` was removed; `composer.lock` is kept. The generator's
post-install step wrote a random `cookieValidationKey` into `config/web.php`.

## Run it

**On the fleet** — nothing to do: `bin/run` (docker runtime) does `docker compose build`
then `docker compose up --remove-orphans` in the foreground. The app listens on
`0.0.0.0:$PORT`; `HEALTH_PATH=/health`; `/` is the stock home page (also About,
Contact, Login with the demo users admin/admin, demo/demo).

**With docker**

    PORT=8080 bin/run              # or: docker compose up --build
    curl localhost:8080/health

**Without docker** (PHP 8.2+, intl recommended, composer):

    FLEET_RUNTIME=process PORT=8080 bin/run
    # = composer install; php yii serve 0.0.0.0 --port=$PORT   (YII_ENV=dev: debug toolbar, Gii)

| step | process runtime | docker runtime |
|---|---|---|
| install | `composer install --no-interaction` | — |
| build | — | `docker compose build` |
| start | `php yii serve 0.0.0.0 --port=$PORT` | `docker compose up --remove-orphans` |

## How the container works

- `Dockerfile`: `dunglas/frankenphp:1-php8.4-bookworm` (+ intl, pdo_pgsql, zip),
  `composer install --no-dev`, `YII_ENV=prod YII_DEBUG=false`, non-root user `app`
  owning `runtime/` and `web/assets/`.
- The command serves with FrankenPHP's stock Caddyfile on `SERVER_NAME=":$PORT"` (plain
  HTTP on the `$PORT` read when the container starts), document root `web/`.
- Database: `config/db.php` is the stock MySQL placeholder and nothing uses it until you
  do; point it at the fleet's `PG*` variables when you add models.

## Deviations from the stock generator output, and why

- `web/index.php`: `YII_DEBUG`/`YII_ENV` read from the environment (stock hard-codes
  dev/true with "comment out in production"). Defaults stay dev locally; the image sets
  prod — it must, since debug/Gii are dev-only packages left out of the image.
- `config/web.php`: `cookieValidationKey` may be overridden by `COOKIE_VALIDATION_KEY`
  (the generated key is committed, so every copy of this template would share it);
  URL rule `health => site/health`.
- `controllers/SiteController.php`: `actionHealth()` returning `{"status":"ok"}`.
- The project's `docker-compose.yml` (yiisoftware/yii2-php apache image, fixed
  `8000:80`, bind mount) was removed: `compose.yaml` replaces it.
- Added `Dockerfile`, `compose.yaml`, `.dockerignore`, `fleet.conf`, `bin/`,
  `.github/workflows/`, `docs/fleet-lifecycle.md`; `.gitignore` gained `.fleet/`,
  `.fleet-deploy.log`, `*.log`.

## Verified

**Not verified yet.** The `docker compose build` / `verify.sh` run was never reached: on
2026-10-05 the shared docker host's disk sat at 0-2 GB free (98 GB volume at 99-100%)
for more than three hours, below the 6 GB gate builds wait for. Before trusting this
template, run `verify.sh <dir> <port>` (run, restart and stop must all pass).

What *was* checked: `migrate.py audit` → READY; `php -l` on every PHP file this template
added or changed, and `sh -n` on its shell scripts → clean.

See `docs/fleet-lifecycle.md` for the lifecycle scripts.
