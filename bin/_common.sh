# shellcheck shell=bash
#
# Shared helpers for the fleet lifecycle scripts (bin/run bin/start bin/restart
# bin/reload bin/stop). Sourced, not executed. Resolves the runtime contract the
# fleet injects (PORT / DATABASE_URL) and loads the per-project
# commands from fleet.conf (at the repo root) — so the lifecycle scripts stay
# project- and language-agnostic and only fleet.conf needs editing per project.
#
# The runtime contract is documented in ../docs/run-script.md at the fleet root.

set -euo pipefail

# This file lives in <repo>/bin, so the repo root is one level up.
FLEET_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$FLEET_ROOT/fleet.conf"
STATE_DIR="$FLEET_ROOT/.fleet"
PIDFILE="$STATE_DIR/app.pid"

mkdir -p "$STATE_DIR"

if [ ! -f "$CONF" ]; then
  echo "fleet: manifest not found at $CONF" >&2
  exit 1
fi

# --- manifest defaults, then the project's fleet.conf overrides them ---------
NAME="app"
HEALTH_PATH="/"
INSTALL_CMD=""
BUILD_CMD=""
START_CMD=""
RELOAD_CMD=""
# The docker runtime's commands (see "runtime" below). Empty = this project has
# no docker runtime, and the commands above are used everywhere.
DOCKER_BUILD_CMD=""
DOCKER_START_CMD=""
DOCKER_RELOAD_CMD=""
FLEET_RUNTIME_DEFAULT="docker"

# The fleet injects PORT (and may set FLEET_RUNTIME) via the environment; those
# must win over fleet.conf. Capture them before sourcing, restore them after.
_ENV_PORT="${PORT:-}"
_ENV_RUNTIME="${FLEET_RUNTIME:-}"
# shellcheck disable=SC1090
. "$CONF"

# --- runtime contract --------------------------------------------------------
# Precedence for PORT: fleet-injected env > fleet.conf > 3000.
export PORT="${_ENV_PORT:-${PORT:-3000}}"
# The fleet serves an app at the ROOT of its own hostname: there is no path prefix.

# --- runtime: a plain process, or containers ---------------------------------
# FLEET_RUNTIME (env, else fleet.conf's FLEET_RUNTIME_DEFAULT) picks how the app runs:
#   docker   DOCKER_BUILD_CMD / DOCKER_START_CMD / DOCKER_RELOAD_CMD (compose.yaml), as
#            containers. The default: the fleet runs every app in the coordinator's private
#            docker (sysbox docker-in-docker; agentmgr sets FLEET_APP_DIND), and there the
#            coordinator binds $PORT itself, for the forwarder that carries the app URL into
#            that docker — a plain process cannot bind it, and the deploy is refused.
#   process  INSTALL_CMD / BUILD_CMD / START_CMD / RELOAD_CMD, as a plain process. Local
#            development without docker only: `FLEET_RUNTIME=process bin/run`.
#   auto     docker when FLEET_APP_DIND is set, else process.
# A fleet.conf whose START_CMD is itself `docker compose up` (no DOCKER_* commands) is left
# exactly as written.
FLEET_RUNTIME="${_ENV_RUNTIME:-${FLEET_RUNTIME_DEFAULT:-docker}}"
if [ "$FLEET_RUNTIME" = "auto" ]; then
  if [ -n "${FLEET_APP_DIND:-}" ]; then FLEET_RUNTIME="docker"; else FLEET_RUNTIME="process"; fi
fi
if [ "$FLEET_RUNTIME" = "docker" ] && [ -n "$DOCKER_BUILD_CMD$DOCKER_START_CMD" ]; then
  INSTALL_CMD=""
  BUILD_CMD="$DOCKER_BUILD_CMD"
  START_CMD="$DOCKER_START_CMD"
  RELOAD_CMD="$DOCKER_RELOAD_CMD"
fi
export FLEET_RUNTIME

# Does this project run its app through compose (either way of saying so)?
uses_compose() {
  case "$START_CMD" in *"docker compose"*|*docker-compose*) return 0 ;; esac
  return 1
}

# A docker command with no daemon to talk to fails deep inside compose; say why up front.
need_docker() { # $1=command
  case "$1" in *docker*) ;; *) return 0 ;; esac
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then return 0; fi
  echo "fleet: $NAME runs in docker (runtime=$FLEET_RUNTIME), but no docker daemon answers here." >&2
  echo "fleet: on the fleet, the coordinator needs its private docker (FLEET_APP_DIND);" >&2
  echo "fleet: locally, start docker or use FLEET_RUNTIME=process bin/run." >&2
  exit 1
}

# Run a command in the foreground (install / build steps). Skips cleanly when
# empty so a project can omit e.g. a build step.
step() { # $1=label  $2=command
  local label="$1" cmd="$2"
  if [ -z "$cmd" ]; then
    echo "fleet: [$label] no command defined — skipping"
    return 0
  fi
  need_docker "$cmd"
  echo "fleet: [$label] $cmd"
  eval "$cmd"
}

# Exec a command AS the foreground server process (the start step). The pidfile
# is written first so bin/stop and bin/restart can find it; because we exec, the
# server keeps this shell's PID, so the pidfile stays accurate.
exec_step() { # $1=label  $2=command
  local label="$1" cmd="$2"
  if [ -z "$cmd" ]; then
    echo "fleet: [$label] no command defined — cannot start $NAME." >&2
    echo "fleet: set ${label^^}_CMD in $CONF" >&2
    exit 1
  fi
  if [ -n "${FLEET_APP_DIND:-}" ] && ! uses_compose; then
    echo "fleet: WARNING — this coordinator runs apps in its private docker ($FLEET_APP_DIND)" >&2
    echo "fleet: and holds :$PORT itself; a plain process cannot bind it. Set DOCKER_START_CMD" >&2
    echo "fleet: (docker compose up) in $CONF." >&2
  fi
  need_docker "$cmd"
  echo "fleet: starting $NAME  (port=$PORT runtime=$FLEET_RUNTIME)"
  echo "fleet: [$label] $cmd"
  echo $$ > "$PIDFILE"
  exec bash -c "$cmd"
}

# Is anything listening on $PORT? With a private docker the app listens there, and the
# coordinator's forwarder on 127.0.0.1:$PORT answers whether the app is up or not.
port_is_up() {
  local host="${FLEET_APP_DIND:-127.0.0.1}"
  if command -v nc >/dev/null 2>&1; then
    nc -z "$host" "$PORT" >/dev/null 2>&1
    return
  fi
  (exec 3<>"/dev/tcp/$host/$PORT") >/dev/null 2>&1
}

# This shell and every process above it. Whatever launched bin/stop or bin/restart —
# the coordinator, its shell, an agent's terminal — is never the app, so the port sweep
# below must never kill it.
_ancestors() {
  local pid=$$ ppid
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    echo "$pid"
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [ -n "$ppid" ] && [ "$ppid" != "$pid" ] || break
    pid="$ppid"
  done
}

# Stop the running instance: prefer the pidfile, fall back to whatever holds
# $PORT. Safe to call when nothing is running.
stop_running() {
  local pid killed=0 own
  own=" $(_ancestors | tr '\n' ' ') "
  if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    # A stale pidfile whose pid now belongs to our own caller is not the app.
    case "$own" in *" $pid "*) pid="" ;; esac
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "fleet: stopping $NAME (pid $pid)"
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
      kill -9 "$pid" 2>/dev/null || true
      killed=1
    fi
    rm -f "$PIDFILE"
  fi
  # Containers outlive a killed `docker compose up`: take the stack down too.
  if uses_compose && command -v docker >/dev/null 2>&1; then
    if [ -n "$(docker compose ps -aq 2>/dev/null || true)" ]; then
      echo "fleet: removing $NAME's containers (docker compose down)"
      docker compose down --remove-orphans >/dev/null 2>&1 || true
      killed=1
    fi
  fi
  # The port sweep. With a private docker, $PORT here is held by the coordinator's own
  # forwarder, never by the app — sweeping it would kill the coordinator. Anywhere else,
  # still never kill this script's own ancestry.
  if [ -z "${FLEET_APP_DIND:-}" ] && command -v lsof >/dev/null 2>&1; then
    local holders="" p
    for p in $(lsof -ti:"$PORT" 2>/dev/null || true); do
      case "$own" in *" $p "*) ;; *) holders="$holders $p" ;; esac
    done
    holders="${holders# }"
    if [ -n "$holders" ]; then
      echo "fleet: freeing port $PORT (pids: $holders)"
      # shellcheck disable=SC2086
      kill $holders 2>/dev/null || true; sleep 0.5
      # shellcheck disable=SC2086
      kill -9 $holders 2>/dev/null || true
      killed=1
    fi
  fi
  if [ "$killed" = 1 ]; then echo "fleet: stopped."; else echo "fleet: nothing was running."; fi
}
