#!/usr/bin/env bash
# Production-like local stack: the four Dockerfiles (backend, imaging, web, floor) built and run
# by the compose `full` profile, against its own database (invai_full), Valkey DB 9 and bucket
# invai-full. The shared dev database `invai` and its Valkey DB 0 are never touched.
#
#   scripts/full.sh up        build one image at a time, start infra + the profile, seed the demo
#                             data if invai_full is empty, then start the worker
#   scripts/full.sh seed      (re)seed invai_full from the host; --force resets it first
#   scripts/full.sh down      stop and remove only the `full` services; infra and volumes stay
#   scripts/full.sh down --purge   also drop invai_full, its bucket, Valkey DB 9 and the images
#
# After `up`: api :3000, imaging :8000, web :5173, floor :5174. Seed logins and the station token
# are in /tmp/invai-full-seed.json. The api and worker run NODE_ENV=production with
# ALLOW_MOCKS=true (mock providers).
set -uo pipefail

export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/share/pnpm:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$INFRA_DIR/.." && pwd)"
COMPOSE_DIR="$INFRA_DIR/local"
SEED_OUT="${FULL_SEED_OUTPUT_FILE:-/tmp/invai-full-seed.json}"
MIN_FREE_GB=6

# Local-only placeholders. They must match the `migrate` service environment in
# local/docker-compose.yml: the host seed encrypts with this FIELD_ENCRYPTION_KEY and talks to
# imaging with this secret, and the containers must read the same data back. BETTER_AUTH_SECRET
# also keys the floor PIN and station hashes (FLOOR_TOKEN_SECRET falls back to it): a seed made
# with another value leaves every PIN "not recognized" in the containers. The host's .env must
# not leak in, so all of these are exported explicitly.
FULL_IMAGING_SECRET="invai-local-full-imaging-secret-00000"
FULL_FIELD_KEY="k1:KzQaGJQ4pwuYge713w7utD2NrzYH21qNtk//UkCed+E="
FULL_AUTH_SECRET="change-me-32-chars-minimum-xxxxxxxx"
FULL_APP_SERVICES="imaging api web floor"
FULL_ALL_SERVICES="api worker imaging web floor migrate full-db-init full-s3-init"

log() { printf '\n==> %s\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
compose() { (cd "$COMPOSE_DIR" && docker compose "$@"); }

need_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not on PATH. Start OrbStack (orb start) and retry."
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable. Run 'orb stop && orb start' and retry."
}

free_gb() { df -g / | awk 'NR==2 {print $4}'; }
check_disk() {
  local free
  free="$(free_gb)"
  [ "${free:-0}" -ge "$MIN_FREE_GB" ] || die "only ${free} GB free on /, need at least ${MIN_FREE_GB} GB. Free space, then retry."
}

wait_healthy() {
  local container="local-$1-1" status="missing" i
  for ((i = 0; i < 60; i++)); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)"
    [ "$status" = "healthy" ] && return 0
    sleep 1
  done
  die "$1 did not become healthy within 60s (last status: $status)"
}

psql_full() { docker exec -i local-postgres-1 psql -U invai -d "$1" -v ON_ERROR_STOP=1 -tA "${@:2}"; }

company_count() {
  psql_full invai_full -c "select count(*) from companies" 2>/dev/null | tr -d '[:space:]'
}

seed_env() {
  export DATABASE_URL="postgres://invai_app:invai@localhost:5432/invai_full"
  export MIGRATION_DATABASE_URL="postgres://invai:invai@localhost:5432/invai_full"
  export REDIS_URL="redis://localhost:6379/9"
  export S3_BUCKET="invai-full" S3_ENDPOINT="http://localhost:9000"
  export S3_ACCESS_KEY_ID="invai" S3_SECRET_ACCESS_KEY="invai-secret" S3_FORCE_PATH_STYLE="true"
  export IMAGING_URL="http://localhost:8000" IMAGING_SHARED_SECRET="$FULL_IMAGING_SECRET"
  export FIELD_ENCRYPTION_KEY="$FULL_FIELD_KEY" BETTER_AUTH_SECRET="$FULL_AUTH_SECRET"
  export BETTER_AUTH_URL="http://localhost:3000" WEB_ORIGIN="http://localhost:5173" FLOOR_ORIGIN="http://localhost:5174"
  export SEED_OUTPUT_FILE="$SEED_OUT"
}

run_seed() {
  local force="${1:-}"
  # The seed parks outbox events and a running worker races it, so the worker is stopped first.
  compose --profile full stop worker >/dev/null 2>&1 || true
  (
    seed_env
    cd "$WORKSPACE_DIR/invai-backend" || exit 1
    if [ "$force" = "--force" ]; then
      pnpm db:reset && pnpm db:migrate || exit 1
    fi
    pnpm db:seed
  ) || die "seed failed (database invai_full; see the output above)"
  echo "   seed output: $SEED_OUT"
}

start_worker() {
  compose --profile full up -d --no-build worker || die "worker did not start"
}

cmd_up() {
  need_docker
  local p
  for p in 3000 5173 5174 8000; do
    if lsof -iTCP:"$p" -sTCP:LISTEN -P -n 2>/dev/null | grep -qv '^COMMAND\|com.docker\|OrbStack\|orbstack'; then
      die "port $p is already in use by another process. Stop it, then retry."
    fi
  done

  log "Starting infra (postgres, valkey, minio, mailpit)"
  compose up -d || die "infra did not start"
  for p in postgres valkey minio mailpit; do wait_healthy "$p"; done

  log "Building images, one at a time (free: $(free_gb) GB)"
  local svc
  for svc in migrate imaging web floor; do
    check_disk
    echo "   building $svc"
    compose --profile full build "$svc" || die "build of $svc failed"
    docker image prune -f >/dev/null 2>&1 || true
  done

  log "Starting full profile (migrate runs first, then api, imaging, web, floor)"
  compose --profile full up -d --no-build --wait $FULL_APP_SERVICES || die "the full profile did not become healthy"

  if [ "$(company_count)" = "0" ]; then
    log "Seeding invai_full (imaging renders real art: allow 15-20 minutes)"
    run_seed
  else
    echo "   invai_full already has data, skipping the seed (full.sh seed --force to redo it)"
  fi

  log "Starting worker"
  start_worker
  echo
  echo "full stack up: api http://localhost:3000  imaging http://localhost:8000  web http://localhost:5173  floor http://localhost:5174"
}

cmd_seed() {
  need_docker
  compose --profile full ps --status running --services 2>/dev/null | grep -q '^imaging$' || die "imaging is not running. Run 'full.sh up' first."
  log "Seeding invai_full from the host"
  run_seed "${1:-}"
  if compose --profile full ps --services 2>/dev/null | grep -q '^api$'; then
    # A reset wipes Valkey DB 9: restart the api so it holds no queue or session state from before.
    [ "${1:-}" = "--force" ] && compose --profile full restart api >/dev/null 2>&1
    start_worker
  fi
}

cmd_down() {
  need_docker
  if [ "${1:-}" = "--purge" ]; then
    log "Purging invai_full, bucket invai-full, Valkey DB 9"
    compose --profile full stop $FULL_ALL_SERVICES >/dev/null 2>&1 || true
    docker exec local-postgres-1 psql -U invai -d postgres -c 'drop database if exists invai_full with (force)' >/dev/null 2>&1 \
      && echo "   dropped database invai_full"
    docker exec local-valkey-1 valkey-cli -n 9 flushdb >/dev/null 2>&1 && echo "   flushed Valkey DB 9"
    compose run --rm --no-deps --entrypoint /bin/sh full-s3-init -c \
      "mc alias set local http://minio:9000 invai invai-secret >/dev/null && mc rb --force local/invai-full" >/dev/null 2>&1 \
      && echo "   removed bucket invai-full"
    rm -f "$SEED_OUT"
  fi
  log "Stopping the full services (infra and volumes stay)"
  compose --profile full rm -sf $FULL_ALL_SERVICES >/dev/null 2>&1
  if [ "${1:-}" = "--purge" ]; then
    docker rmi -f invai-full-backend:local invai-full-imaging:local invai-full-web:local invai-full-floor:local >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
    echo "   removed images invai-full-*:local"
  fi
  echo "full profile is down"
}

case "${1:-}" in
  up) cmd_up ;;
  seed) cmd_seed "${2:-}" ;;
  down) cmd_down "${2:-}" ;;
  *) echo "usage: full.sh up | seed [--force] | down [--purge]" >&2; exit 2 ;;
esac
