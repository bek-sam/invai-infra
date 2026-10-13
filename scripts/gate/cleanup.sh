#!/usr/bin/env bash
# Gate cleanup (T-42-2). Sourced by gate.sh after lib.sh and scratch.sh.
#
# Every gate run seeds the scratch database invai_gate and writes about 150 MB of files into the
# local MinIO bucket under that seed's company ids. This file removes those files at the end of
# every run (EXIT trap) and, for a run that was killed without its trap, at the start of the next
# one (A2), and flushes the scratch Valkey DB. Only prefixes read from invai_gate.companies are
# ever deleted, each as the exact `<uuid>/` prefix.

GATE_TOOLS_DIR="${GATE_TOOLS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
GATE_PG_CONTAINER="${GATE_PG_CONTAINER:-local-postgres-1}"
GATE_CLEANUP_ARMED=0

# gate_s3 <args>: the MinIO helper (tests replace this function or set GATE_S3_TOOL).
gate_s3() {
  if [ -n "${GATE_S3_TOOL:-}" ]; then "$GATE_S3_TOOL" "$@"; else node "$GATE_TOOLS_DIR/s3tool.mjs" "$@"; fi
}

# gate_company_ids <database>: company ids, one per line. Fails when the database or table is
# unreachable, so "no answer" is never read as "no companies".
gate_company_ids() {
  docker exec "$GATE_PG_CONTAINER" psql -U invai -d "$1" -v ON_ERROR_STOP=1 -Atc "select id from companies" 2>/dev/null
}

# gate_valid_prefix <prefix>: exactly a lowercase UUID plus the trailing slash.
gate_valid_prefix() {
  case "$1" in
    ????????-????-????-????-????????????/) ;;
    *) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/$'
}

# gate_flush_valkey_db <db>: flushes one Valkey DB, and only the gate's own (9).
gate_flush_valkey_db() {
  local db="$1" who
  if [ "$db" != 9 ]; then
    log "cleanup refused: Valkey DB '$db' is not the gate's DB 9"
    return 1
  fi
  if who="$(gate_full_profile_running)"; then
    log "cleanup refused: compose full profile is running ($who) and shares Valkey DB 9"
    return 1
  fi
  docker exec "${GATE_VALKEY_CONTAINER:-local-valkey-1}" valkey-cli -n 9 FLUSHDB >>"$LOG_FILE" 2>&1
}

# gate_cleanup_files <label>: delete the MinIO prefixes of every company in invai_gate.
# Logs one line with the prefix count and bytes removed.
gate_cleanup_files() {
  local label="$1" ids live id out n=0 objs=0 bytes=0 rc=0 o b
  if [ "$GATE_DB_NAME" != invai_gate ]; then
    log "cleanup refused: database '$GATE_DB_NAME' is not exactly invai_gate"
    return 1
  fi
  if ! ids="$(gate_company_ids "$GATE_DB_NAME")"; then
    log "gate cleanup ($label): cannot read $GATE_DB_NAME.companies; no files deleted"
    return 0
  fi
  live="$(gate_company_ids invai)"
  if [ -z "$live" ]; then
    log "cleanup refused: cannot read the company list of the dev database invai (empty); no files deleted"
    return 1
  fi
  for id in $ids; do
    if ! gate_valid_prefix "$id/"; then
      log "cleanup refused prefix '$id/': not a UUID"
      rc=1
      continue
    fi
    if printf '%s\n' "$live" | grep -qxF "$id"; then
      log "cleanup refused prefix '$id/': it is a company in the dev database invai"
      rc=1
      continue
    fi
    if ! out="$(gate_s3 delete-prefix "$id/" 2>>"$LOG_FILE")"; then
      log "cleanup: delete of '$id/' failed"
      rc=1
      continue
    fi
    o="${out%%$'\t'*}"; b="${out##*$'\t'}"
    objs=$((objs + ${o:-0})); bytes=$((bytes + ${b:-0})); n=$((n + 1))
  done
  log "gate cleanup ($label): removed $n company prefixes, $objs objects, $bytes bytes from MinIO"
  return $rc
}

# gate_cleanup_run <label>: files first, then the scratch Valkey DB.
gate_cleanup_run() {
  local label="$1"
  gate_cleanup_files "$label"
  if gate_flush_valkey_db "${GATE_REDIS_DB:-9}"; then
    log "gate cleanup ($label): Valkey DB 9 flushed"
  fi
}
