#!/usr/bin/env bash
# Wipes local Postgres (invai + invai_test) and re-runs local/init.sql from scratch, then
# re-runs invai-backend's migrations if available. Valkey and MinIO are untouched.
set -uo pipefail

export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/share/pnpm:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$INFRA_DIR/.." && pwd)"

warn() { printf 'WARN: %s\n' "$1" >&2; }

echo "==> Resetting local Postgres (invai + invai_test) — ALL local data in it is discarded"
cd "$INFRA_DIR/local"
docker compose stop postgres
docker compose rm -f postgres
docker volume rm local_pgdata >/dev/null 2>&1 || true
docker compose up -d postgres

echo "==> Waiting for postgres to be healthy"
tries=60
status="unknown"
for ((i = 0; i < tries; i++)); do
  status="$(docker inspect --format '{{.State.Health.Status}}' local-postgres-1 2>/dev/null || echo "missing")"
  [ "$status" = "healthy" ] && break
  sleep 1
done
if [ "$status" != "healthy" ]; then
  echo "postgres did not become healthy within ${tries}s (status: $status)" >&2
  exit 1
fi
echo "   postgres: healthy, invai + invai_test re-initialized from local/init.sql"

if [ -d "$WORKSPACE_DIR/invai-backend" ] && grep -q '"db:migrate"' "$WORKSPACE_DIR/invai-backend/package.json" 2>/dev/null; then
  echo "==> Re-running invai-backend migrations"
  (cd "$WORKSPACE_DIR/invai-backend" && pnpm db:migrate) || warn "db:migrate failed — run it manually once fixed"
else
  warn "invai-backend db:migrate script not found — run migrations manually"
fi
