#!/usr/bin/env bash
# Shared CI E2E stack start-up + run (T-23-7), called identically from the e2e.yml workflow in
# invai-backend, invai-web and invai-floor. Never touches a real cloud account: every URL below
# is localhost, and this never runs `sst`, `aws` or a deploy.
#
# Assumes, before this script runs:
#   - invai-contracts, invai-ui, invai-backend, invai-web, invai-floor, invai-imaging and
#     invai-infra are checked out as siblings under one workspace directory (this file's own
#     `../..` is invai-infra, so `../../..` from here is that workspace directory).
#   - `pnpm install --frozen-lockfile` already ran in contracts, ui, backend, web, floor, and
#     `uv sync --all-groups` in imaging.
#   - Postgres (pgvector), Valkey and MinIO are already reachable at the URLs below, and the
#     `invai_app` role + extensions already exist in Postgres (mirrors local/init.sql; the
#     calling workflow runs the same SQL invai-backend/.github/workflows/ci.yml already uses).
#   - The calling workflow exported the env vars below (DATABASE_URL, REDIS_URL, S3_*, etc.) at
#     the job level, so every process started here inherits them.
#
# Order matters (run-golden-path step order): imaging must be up before the seed renders real
# art, so imaging starts first, then api + worker, then migrate + seed, then web + floor (which
# don't need seeded data until a browser hits them). Every process is started fresh here (no
# prior dev.sh pass on this DB), so there is no restart-once dance to do.
set -uo pipefail

export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/share/pnpm:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_DIR="$(cd "$INFRA_DIR/.." && pwd)"
LOG_DIR="${LOG_DIR:-$WORKSPACE_DIR/.ci-e2e-logs}"
mkdir -p "$LOG_DIR"

PIDS=()

cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    [ -z "$pid" ] && continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "${PIDS[@]:-}"; do
    [ -z "$pid" ] && continue
    kill -KILL "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

log() { printf '==> %s\n' "$*"; }

wait_http_ok() {
  local url="$1" name="$2" tries=90 i
  for ((i = 0; i < tries; i++)); do
    curl -sf -o /dev/null "$url" && { log "$name: healthy ($url)"; return 0; }
    sleep 1
  done
  log "FAIL: $name did not become healthy at $url within ${tries}s"
  return 1
}

start() {
  local name="$1" dir="$2"
  shift 2
  ( cd "$dir" && exec "$@" ) >"$LOG_DIR/$name.log" 2>&1 &
  PIDS+=("$!")
  log "started $name (pid $!) in $dir: $*"
}

export MOCK_CARRIER_TRANSIT_HOURS="${MOCK_CARRIER_TRANSIT_HOURS:-0.001}"

# Ports default to the real stack's (matches what CI's env: block and the local dev stack both
# use). A local proof run of this script (never the CI job itself) overrides these, plus
# DATABASE_URL/MIGRATION_DATABASE_URL/REDIS_URL/IMAGING_URL/VITE_API_URL/E2E_*_URL, to run
# alongside an already-running dev stack on the default ports without touching it.
API_PORT="${API_PORT:-3000}"
IMAGING_PORT="${IMAGING_PORT:-8000}"
WEB_PORT="${WEB_PORT:-5173}"
FLOOR_PORT="${FLOOR_PORT:-5174}"
export PORT="$API_PORT"

log "starting imaging"
start imaging "$WORKSPACE_DIR/invai-imaging" .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port "$IMAGING_PORT"
wait_http_ok "http://localhost:$IMAGING_PORT/health" imaging || exit 1

log "starting api"
start api "$WORKSPACE_DIR/invai-backend" node_modules/.bin/tsx src/api/server.ts
wait_http_ok "http://localhost:$API_PORT/health" api || exit 1

log "starting worker"
start worker "$WORKSPACE_DIR/invai-backend" node_modules/.bin/tsx src/worker/index.ts

log "migrate"
( cd "$WORKSPACE_DIR/invai-backend" && node_modules/.bin/tsx src/db/migrate.ts ) 2>&1 | tee "$LOG_DIR/migrate.log"
migrate_rc=${PIPESTATUS[0]}
if [ "$migrate_rc" -ne 0 ]; then
  log "FAIL: db:migrate failed, see $LOG_DIR/migrate.log"
  exit 1
fi

log "seed (imaging + worker are up, so gang sheets render real art)"
( cd "$WORKSPACE_DIR/invai-backend" && node_modules/.bin/tsx src/db/seed/index.ts ) 2>&1 | tee "$LOG_DIR/seed.log"
seed_rc=${PIPESTATUS[0]}
if [ "$seed_rc" -ne 0 ]; then
  log "FAIL: db:seed failed, see $LOG_DIR/seed.log"
  exit 1
fi

log "starting web"
start web "$WORKSPACE_DIR/invai-web" node_modules/.bin/vite --port "$WEB_PORT" --strictPort
wait_http_ok "http://localhost:$WEB_PORT" web || exit 1

log "starting floor"
start floor "$WORKSPACE_DIR/invai-floor" node_modules/.bin/vite --port "$FLOOR_PORT" --strictPort
wait_http_ok "http://localhost:$FLOOR_PORT" floor || exit 1

export E2E_WEB_URL="${E2E_WEB_URL:-http://localhost:$WEB_PORT}"
export E2E_API_URL="${E2E_API_URL:-http://localhost:$API_PORT}"
export E2E_FLOOR_URL="${E2E_FLOOR_URL:-http://localhost:$FLOOR_PORT}"

FAILED=0

log "== API golden path (invai-web e2e/api-golden-path.spec.ts) =="
( cd "$WORKSPACE_DIR/invai-web" && E2E_API=1 node_modules/.bin/playwright test e2e/api-golden-path.spec.ts ) \
  2>&1 | tee "$LOG_DIR/api-golden-path.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || FAILED=1

log "== browser suite (invai-web: golden path + screens smoke) =="
( cd "$WORKSPACE_DIR/invai-web" && node_modules/.bin/playwright test ) 2>&1 | tee "$LOG_DIR/web-e2e.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || FAILED=1

log "== floor suite (invai-floor) =="
( cd "$WORKSPACE_DIR/invai-floor" && node_modules/.bin/playwright test ) 2>&1 | tee "$LOG_DIR/floor-e2e.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || FAILED=1

if [ "$FAILED" -ne 0 ]; then
  log "one or more E2E suites failed; logs are in $LOG_DIR, traces under invai-web/e2e/.results and invai-floor/e2e/.results"
fi

exit "$FAILED"
