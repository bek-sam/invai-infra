#!/usr/bin/env bash
# Stops local infra (postgres, valkey, minio, mailpit, and any `full` profile app
# containers). Data volumes (pgdata, miniodata) are kept — use reset-db.sh to wipe Postgres.
#
# App processes started by scripts/dev.sh (api/worker/imaging/web/floor) run in the
# foreground under `concurrently`; stop those with Ctrl-C in that terminal. This script only
# stops the dockerized infra.
set -uo pipefail

export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/share/pnpm:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Stopping infra (pgdata and miniodata volumes are kept)"
cd "$INFRA_DIR/local"
docker compose --profile full down
echo "==> Done. Run scripts/dev.sh (or 'pnpm local:up') to start again."
