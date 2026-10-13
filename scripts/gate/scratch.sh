#!/usr/bin/env bash
# Gate scratch database (T-41-4). Sourced by gate.sh after lib.sh.
#
# The golden-path phase resets, migrates and seeds a scratch database `invai_gate` (Valkey DB 9,
# its own seed-output file) so a gate never wipes the dev DB `invai` and the AI photo sets that
# live in it. Everything the gate starts inherits these variables; the backend loads .env with
# process.loadEnvFile (src/env.ts:18-21), which never overrides a variable already set.

GATE_DB_NAME="${GATE_DB_NAME:-invai_gate}"
GATE_REDIS_DB=9

gate_scratch_vars() {
  GATE_DATABASE_URL="postgres://invai_app:invai@localhost:5432/$GATE_DB_NAME"
  GATE_MIGRATION_DATABASE_URL="postgres://invai:invai@localhost:5432/$GATE_DB_NAME"
  GATE_REDIS_URL="redis://localhost:6379/$GATE_REDIS_DB"
  GATE_SEED_FILE="$GATE_DIR/seed-output.json"
}

# Path part of a URL, minus the slash and any query.
_url_db() { local p="${1#*://}"; p="${p#*/}"; echo "${p%%\?*}"; }

# gate_scratch_check <database url> <migration url> <redis url>: prints a reason and returns 1 when
# any of them could point at the dev database or Valkey DB 0 (AC5, A8).
gate_scratch_check() {
  local d m r
  d="$(_url_db "$1")"; m="$(_url_db "$2")"; r="$(_url_db "$3")"
  [ "$d" = invai ] && { echo "DATABASE_URL names the dev database 'invai'"; return 1; }
  [ "$m" = invai ] && { echo "MIGRATION_DATABASE_URL names the dev database 'invai'"; return 1; }
  [ -z "$d" ] || [ -z "$m" ] && { echo "a database URL has no database name"; return 1; }
  [ "$r" = "$GATE_REDIS_DB" ] || { echo "REDIS_URL is not Valkey DB $GATE_REDIS_DB"; return 1; }
  return 0
}

# gate_refuse_paid_ai: spend on invai_gate would escape the dev ledger (A8).
gate_refuse_paid_ai() {
  if [ -n "${INVAI_PAID_AI:-}" ]; then echo "INVAI_PAID_AI is set"; return 1; fi
  if [ -n "${IMAGE_GEN_PROVIDER:-}" ]; then echo "IMAGE_GEN_PROVIDER is set"; return 1; fi
  return 0
}

# gate_scratch_env: export the scratch variables for every child the golden path starts.
gate_scratch_env() {
  local why
  gate_scratch_vars
  why="$(gate_scratch_check "$GATE_DATABASE_URL" "$GATE_MIGRATION_DATABASE_URL" "$GATE_REDIS_URL")" \
    || refuse "scratch guard: $why"
  export DATABASE_URL="$GATE_DATABASE_URL" MIGRATION_DATABASE_URL="$GATE_MIGRATION_DATABASE_URL"
  export REDIS_URL="$GATE_REDIS_URL" SEED_OUTPUT_FILE="$GATE_SEED_FILE" E2E_SEED_OUTPUT_FILE="$GATE_SEED_FILE"
  log "gate database: $GATE_DB_NAME (dev database invai is not touched); valkey DB $GATE_REDIS_DB; seed output $GATE_SEED_FILE"
}

# ---------- gate bucket (T-45-5, B-402) ----------
#
# Every golden-path child that touches S3 (imaging, the seed, api, worker) writes to the gate's own
# bucket, never the dev bucket invai-local. Both apps let an exported S3_BUCKET beat their .env
# file (backend src/env.ts loadEnvFile never overrides; imaging pydantic-settings ranks env above
# env_file). It is exported only inside the golden path, after the per-repo suites: the backend
# `pnpm test` refuses any bucket that is not a test bucket.

GATE_S3_BUCKET=invai-gate

# gate_bucket_check <bucket>: allow-list, exactly invai-gate. Prints a reason and returns 1 otherwise.
gate_bucket_check() {
  [ -n "$1" ] || { echo "S3_BUCKET is empty"; return 1; }
  [ "$1" = "$GATE_S3_BUCKET" ] || { echo "S3_BUCKET is '$1', not $GATE_S3_BUCKET"; return 1; }
  return 0
}

# gate_bucket_env: export S3_BUCKET=invai-gate for the golden-path children, then verify the
# effective value (refuses on anything but invai-gate).
gate_bucket_env() {
  local why
  export S3_BUCKET="$GATE_S3_BUCKET"
  why="$(gate_bucket_check "${S3_BUCKET:-}")" || refuse "bucket guard: $why"
  log "gate bucket: $S3_BUCKET (dev bucket invai-local is not written or deleted)"
}

# gate_ensure_bucket: create invai-gate when missing (idempotent), before the seed.
gate_ensure_bucket() {
  S3_BUCKET="$GATE_S3_BUCKET" gate_s3 ensure-bucket >>"$LOG_FILE" 2>&1
}

# gate_ensure_db: create invai_gate (owner invai) when missing and let the app role connect (A7).
gate_ensure_db() {
  local have
  have="$(docker exec local-postgres-1 psql -U invai -d postgres -Atc \
    "select 1 from pg_database where datname='$GATE_DB_NAME'" 2>>"$LOG_FILE")" || return 1
  if [ "$have" != 1 ]; then
    docker exec local-postgres-1 psql -U invai -d postgres -v ON_ERROR_STOP=1 -c \
      "create database $GATE_DB_NAME owner invai" >>"$LOG_FILE" 2>&1 || return 1
    log "created database $GATE_DB_NAME"
  fi
  docker exec local-postgres-1 psql -U invai -d postgres -v ON_ERROR_STOP=1 -c \
    "grant connect on database $GATE_DB_NAME to invai_app" >>"$LOG_FILE" 2>&1
}

# ---------- floor seed-output swap (AC2, A9) ----------
#
# The floor E2E helper reads the fixed invai-backend/seed-output.json. For the floor suite only,
# the gate copies its own seed output there and puts the dev file back on every exit path. The
# backup file survives SIGKILL; every gate start restores from it first.

gate_dev_seed_file() { echo "$WORKSPACE_DIR/invai-backend/seed-output.json"; }
gate_seed_backup() { echo "$GATE_DIR/seed-output.dev.json"; }
GATE_SEED_SWAPPED=0

gate_restore_dev_seed() {
  local dev bak
  dev="$(gate_dev_seed_file)"; bak="$(gate_seed_backup)"
  if [ -f "$bak" ]; then
    cp "$bak" "$dev" && rm -f "$bak" && log "restored dev seed-output.json from backup at $(date -u +%H:%M:%SZ)"
  fi
  GATE_SEED_SWAPPED=0
}

gate_swap_dev_seed() {
  local dev bak
  dev="$(gate_dev_seed_file)"; bak="$(gate_seed_backup)"
  [ -f "$GATE_SEED_FILE" ] || { log "no gate seed output to swap in"; return 1; }
  [ -f "$dev" ] && cp "$dev" "$bak"
  GATE_SEED_SWAPPED=1
  cp "$GATE_SEED_FILE" "$dev" || return 1
  log "floor seed swap start $(date -u +%H:%M:%SZ) (dev sha256 $( [ -f "$bak" ] && shasum -a 256 "$bak" | cut -c1-12 ))"
}
