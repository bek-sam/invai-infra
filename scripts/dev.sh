#!/usr/bin/env bash
# One-command local dev: starts infra, runs backend migrations (+ seed, if present), then
# starts api, worker, imaging, web and floor together with prefixed logs.
#
# Usage: ./scripts/dev.sh   (or, from invai-infra: pnpm dev:all)
#
# Infra (postgres/valkey/minio/mailpit) is left running when this exits (Ctrl-C only stops
# the five app processes below, started in the foreground via `concurrently`). Use
# scripts/stop.sh to also stop infra.
set -uo pipefail

# Every shell in this workspace that uses node/pnpm must set this itself (see CLAUDE.md) —
# the system /usr/local/bin/node is Node 22 and must not be used.
export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/share/pnpm:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$INFRA_DIR/.." && pwd)"

# shellcheck source=gate/ports.sh
source "$SCRIPT_DIR/gate/ports.sh"
resolve_ports || { echo "dev.sh: $PORT_ERROR" >&2; exit 1; }

log() { printf '\n==> %s\n' "$1"; }
warn() { printf 'WARN: %s\n' "$1" >&2; }

wait_healthy() {
  local container="local-$1-1"
  local tries=60
  for ((i = 0; i < tries; i++)); do
    local status
    status="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")"
    if [ "$status" = "healthy" ]; then
      echo "   $1: healthy"
      return 0
    fi
    sleep 1
  done
  warn "$1 did not become healthy within ${tries}s (last status: ${status:-unknown})"
  return 1
}

command -v docker >/dev/null 2>&1 || {
  echo "docker is not on PATH. Start OrbStack (orb start) and retry." >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  echo "docker daemon is not reachable. Run 'orb start' (OrbStack) and retry." >&2
  exit 1
}

log "Starting infra (postgres, valkey, minio, mailpit)"
(cd "$INFRA_DIR/local" && docker compose up -d) || {
  echo "Failed to start local infra. Aborting." >&2
  exit 1
}

log "Waiting for infra health checks"
wait_healthy postgres
wait_healthy valkey
wait_healthy minio
wait_healthy mailpit

log "Backend: install, migrate, seed"
if [ -d "$WORKSPACE_DIR/invai-backend" ]; then
  (
    cd "$WORKSPACE_DIR/invai-backend"
    [ -f .env ] || { [ -f .env.example ] && cp .env.example .env && echo "   created .env from .env.example"; }
    if [ ! -d node_modules ]; then
      echo "   installing invai-backend dependencies"
      pnpm install
    fi
    if grep -q '"db:migrate"' package.json 2>/dev/null; then
      pnpm db:migrate || warn "invai-backend db:migrate failed (see output above) — continuing"
    else
      warn "invai-backend has no db:migrate script yet — skipping"
    fi
    # Coordinate: invai-backend's seed script may not exist yet (another agent is writing
    # it). Tolerate that with a warning instead of failing the whole dev run.
    if grep -q '"db:seed"' package.json 2>/dev/null; then
      pnpm db:seed || warn "invai-backend db:seed failed (see output above) — continuing"
    else
      warn "invai-backend has no db:seed script yet — skipping seed"
    fi
  )
else
  warn "invai-backend not found next to invai-infra — skipping migrate/seed"
fi

for repo in invai-web invai-floor; do
  dir="$WORKSPACE_DIR/$repo"
  if [ -d "$dir" ] && [ ! -d "$dir/node_modules" ]; then
    log "Installing $repo dependencies"
    (cd "$dir" && pnpm install) || warn "$repo install failed — continuing"
  fi
done

if [ -d "$WORKSPACE_DIR/invai-imaging" ] && [ ! -d "$WORKSPACE_DIR/invai-imaging/.venv" ]; then
  log "Installing invai-imaging dependencies (uv sync)"
  (cd "$WORKSPACE_DIR/invai-imaging" && uv sync --all-groups) || warn "invai-imaging uv sync failed — continuing"
fi

if [ ! -d "$INFRA_DIR/node_modules/concurrently" ]; then
  log "Installing invai-infra dependencies (concurrently)"
  (cd "$INFRA_DIR" && pnpm install)
fi

# T-2-6 (qa-engineer): CSV-only channels (Etsy, Amazon, TikTok, Walmart while on CSV) now ship
# on the mock carrier's first scan instead of at push time (T-2-5). The mock carrier fakes that
# scan after MOCK_CARRIER_TRANSIT_HOURS (backend default: 2h). Keep it low here so local dev and
# the golden-path E2E suites see items reach `shipped` in seconds; an agent may still override it.
export MOCK_CARRIER_TRANSIT_HOURS="${MOCK_CARRIER_TRANSIT_HOURS:-0.001}"

log "Starting api, worker, imaging, web, floor (Ctrl-C stops these; infra keeps running)"
cd "$INFRA_DIR"
# Per-command env (never global): the web SPA gets VITE_API_URL, the floor gets VITE_API_PROXY.
# Both are set only when INVAI_API_PORT is, so the default path is unchanged. --strictPort makes
# vite fail instead of drifting to a neighbour port.
web_env=""
floor_env=""
if [ -n "${INVAI_API_PORT:-}" ]; then
  web_env="VITE_API_URL=http://localhost:$API_PORT "
  floor_env="VITE_API_PROXY=http://localhost:$API_PORT "
fi
# B-388: the gate sets INVAI_NO_WATCH=1 so a backend or imaging edit cannot restart the stack mid-run.
api_cmd="pnpm dev:api"
worker_cmd="pnpm dev:worker"
imaging_reload=" --reload"
if [ "${INVAI_NO_WATCH:-}" = 1 ]; then
  api_cmd="pnpm exec tsx --import ./src/lib/telemetry.ts src/api/server.ts"
  worker_cmd="pnpm exec tsx --import ./src/lib/telemetry.ts src/worker/index.ts"
  imaging_reload=""
fi
exec node_modules/.bin/concurrently \
  --names "api,worker,imaging,web,floor" \
  --prefix-colors "blue,magenta,green,yellow,cyan" \
  --prefix "[{name}]" \
  "cd ../invai-backend && $api_cmd" \
  "cd ../invai-backend && $worker_cmd" \
  "cd ../invai-imaging && uv run uvicorn app.main:app --host 0.0.0.0 --port $IMAGING_PORT$imaging_reload" \
  "cd ../invai-web && ${web_env}pnpm dev --port $WEB_PORT --strictPort" \
  "cd ../invai-floor && ${floor_env}pnpm dev --port $FLOOR_PORT --strictPort"
