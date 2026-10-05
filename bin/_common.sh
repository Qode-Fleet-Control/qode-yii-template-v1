# shellcheck shell=bash
#
# Shared helpers for the fleet lifecycle scripts (bin/run bin/start bin/restart
# bin/reload bin/stop). Sourced, not executed. Resolves the runtime contract the
# fleet injects (PORT / BASE_PATH / DATABASE_URL) and loads the per-project
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

# The fleet injects PORT via the environment; that must win over fleet.conf's
# default. Capture it before sourcing, restore it after.
_ENV_PORT="${PORT:-}"
# shellcheck disable=SC1090
. "$CONF"

# --- runtime contract --------------------------------------------------------
# Precedence for PORT: fleet-injected env > fleet.conf > 3000.
export PORT="${_ENV_PORT:-${PORT:-3000}}"
# BASE_PATH is fleet-injected only; empty when running standalone (domain root).
export BASE_PATH="${BASE_PATH:-}"

# Run a command in the foreground (install / build steps). Skips cleanly when
# empty so a project can omit e.g. a build step.
step() { # $1=label  $2=command
  local label="$1" cmd="$2"
  if [ -z "$cmd" ]; then
    echo "fleet: [$label] no command defined — skipping"
    return 0
  fi
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
  echo "fleet: starting $NAME  (port=$PORT base_path=${BASE_PATH:-/})"
  echo "fleet: [$label] $cmd"
  echo $$ > "$PIDFILE"
  exec bash -c "$cmd"
}

# Is anything listening on $PORT?
port_is_up() {
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1
    return
  fi
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") >/dev/null 2>&1
}

# Stop the running instance: prefer the pidfile, fall back to whatever holds
# $PORT. Safe to call when nothing is running.
stop_running() {
  local pid killed=0
  if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "fleet: stopping $NAME (pid $pid)"
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
      kill -9 "$pid" 2>/dev/null || true
      killed=1
    fi
    rm -f "$PIDFILE"
  fi
  if command -v lsof >/dev/null 2>&1; then
    local holders
    holders="$(lsof -ti:"$PORT" 2>/dev/null || true)"
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
