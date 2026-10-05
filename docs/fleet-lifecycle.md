# fleet-template-v1

## What This Template Is

`fleet-template-v1` is a **language-agnostic app lifecycle harness** for apps
managed by the fleet platform. It gives any app — Node, Python, Go, a Docker
Compose stack, anything — a uniform way to be deployed and controlled, without
the fleet needing to know a single thing about your stack.

The fleet injects runtime variables into the environment (`PORT`,
`DATABASE_URL`) and calls `./bin/run` to deploy. Everything project-specific —
how to install, build, and start your app — lives in **one file: `fleet.conf`**.
That is the only file you edit per project.

## Repository Structure

```
fleet.conf        ← the only file you edit per project
.env              ← local-only env vars (gitignored)
bin/
  _common.sh      ← shared logic; never edit this
  run             ← install + build + start (called by the fleet)
  start           ← start only (no rebuild)
  restart         ← stop + full run
  reload          ← hot-reload config without rebuild
  stop            ← stop the running process
```

## The One File You Edit: `fleet.conf`

`fleet.conf` is sourced as shell by the lifecycle scripts. Fill in the commands
for your stack; leave any command empty (`''`) to skip that step.

```sh
NAME="my-app"           # label shown in fleet logs
PORT="3000"             # default port (fleet overrides via $PORT env var)
HEALTH_PATH="/"         # HTTP path that returns 200 when the app is ready

INSTALL_CMD='npm ci'
BUILD_CMD='npm run build'
START_CMD='node dist/server.js'   # must listen on $PORT; run in foreground
RELOAD_CMD=''           # optional; empty → falls back to stop+start
```

> **Critical rule:** single-quote any command that uses `$PORT`.
> Single quotes defer variable expansion to **runtime** — when the
> command actually runs, with the fleet-injected value — rather than at the
> moment `fleet.conf` is sourced (when that value isn't set yet). Use
> `START_CMD='gunicorn app:app --bind 0.0.0.0:$PORT'`, never double quotes.

## The docker runtime

`bin/_common.sh` picks the commands by `FLEET_RUNTIME`:

| `FLEET_RUNTIME` | Runs | Where |
| --- | --- | --- |
| `docker` (default) | `DOCKER_BUILD_CMD` → `DOCKER_START_CMD` | the fleet: every coordinator has a private docker (sysbox docker-in-docker) |
| `process` | `INSTALL_CMD` → `BUILD_CMD` → `START_CMD` | the QA tester's self-host, and local work without docker |
| `auto` | docker when `FLEET_APP_DIND` is set, else process | |

On the fleet the coordinator itself holds `$PORT` and forwards it into its private
docker, so the app **must** run as a container publishing `${PORT}:${PORT}` — a plain
process cannot bind the port, and the coordinator refuses to deploy a `fleet.conf`
without `DOCKER_START_CMD`. `compose.yaml` must:

- build the app's `Dockerfile`, serving on `0.0.0.0:$PORT` inside the container;
- publish `"${PORT:-3000}:${PORT:-3000}"` and set `PORT: ${PORT:-3000}`;
- list the fleet's variables under `environment:` **without values** (`DATABASE_URL:`,
  `REDIS_URL:`, `S3_ENDPOINT:` …) so compose passes them through — the fleet attaches the
  workspace's Postgres / Redis / MinIO / Mailpit to the private docker under the very
  hostnames those URLs name;
- keep any database it brings for local work under a `local` profile, so it never starts
  on the fleet.

`compose.yaml` here is that skeleton. Locally, `PORT=3001 bin/run` runs the docker
runtime; `FLEET_RUNTIME=process PORT=3001 bin/run` runs the plain process.

## How the Lifecycle Works

| Script | What it does | When to use |
| --- | --- | --- |
| `bin/run` | `INSTALL_CMD` → `BUILD_CMD` → `START_CMD` | Fleet deploy, fresh start |
| `bin/start` | `START_CMD` only | Restart without rebuild |
| `bin/restart` | stop + `bin/run` | After a code/dep change |
| `bin/reload` | `RELOAD_CMD`, or stop+start if empty | After a config-only change |
| `bin/stop` | Kill by pidfile, `docker compose down`, free the port | Tear down |

> The process PID is written to `.fleet/app.pid` so subsequent `stop`/`restart`
> calls can find and terminate it reliably. If the pidfile is missing or stale,
> `stop` falls back to freeing whatever is listening on `$PORT`.

## How to Apply This to Your Project

### Step 1 — Copy the template into your repo

```sh
cp -r fleet-template-v1/* my-project/
```

Or, if starting fresh, just clone it and work from `main`.

### Step 2 — Edit `fleet.conf` (the only required change)

Fill in your stack's commands. Per-stack examples:

```sh
# Node.js
INSTALL_CMD='npm ci'
BUILD_CMD='npm run build'
START_CMD='node dist/index.js'

# Python (Gunicorn)
INSTALL_CMD='pip install -r requirements.txt'
BUILD_CMD=''
START_CMD='gunicorn app:app --bind 0.0.0.0:$PORT'

# Go
INSTALL_CMD=''
BUILD_CMD='go build -o ./out/server ./cmd/server'
START_CMD='./out/server'

# Docker runtime (required on the fleet, alongside one of the above)
DOCKER_BUILD_CMD='docker compose build'
DOCKER_START_CMD='docker compose up --remove-orphans'
```

### Step 3 — Set local env vars in `.env` (gitignored)

```sh
APP_NAME=My App
DATABASE_URL=postgres://localhost/mydb
```

### Step 4 — Verify standalone

```sh
PORT=3001 bin/run      # should install, build, and serve on 3001
curl http://localhost:3001/   # should 200
```

### Step 5 — Connect to the fleet

Point the fleet at your repo. It will clone it, inject `PORT` /
`DATABASE_URL`, and call `bin/run`. As long as your `START_CMD` listens on
`$PORT` and `HEALTH_PATH` returns 200, the fleet will mark the app healthy.

## Key Invariants

- **`START_CMD` must run in the foreground and listen on `$PORT`.** Do not use a
  dev server — HMR / hot-reload chunks 404 behind the ingress and will break the
  app.
- **Never put secrets in `fleet.conf`** — it's committed. Use `.env` locally;
  the fleet injects secrets via the environment.
- **`bin/_common.sh` is shared infrastructure** — don't edit it per project. All
  project-specific configuration belongs in `fleet.conf`.
