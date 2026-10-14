#!/usr/bin/env bash
# The gate's own backend test database (T-46-1, B-426). Sourced by gate.sh after lib.sh.
#
# Wave 45 run 1: the backend suite ran on the shared name `invai_test` (pinned) and a shared
# Valkey DB, so any other process that started a vitest or truncated that name emptied tables
# under the running suite (13 failures, FK 23503 "company not found"); run 2 on the same SHAs
# passed. The gate now gives its backend `pnpm test`:
#   - Postgres: a database only this run knows, `invai_test_gate_<UTC stamp>_<pid>`, created here,
#     pinned through TEST_DATABASE_URL / TEST_MIGRATION_DATABASE_URL (the harness migrates and
#     truncates it; db-safety.ts accepts it because "test" is a whole segment), and dropped when
#     the suite ends and again by the EXIT trap. The stale-drop regex of the harness
#     (`^invai_test_[0-9]+$`) can never match it, and neither can this file's regex match theirs.
#   - Valkey: the harness claim (DB 1-14, registry DB 15). No gate-only DB exists there, so the
#     suite runs with REDIS_URL on DB 0's base URL and no TEST_REDIS_URL; the claimed DB is read
#     back from the registry and logged.
#   - Detection: PGAPPNAME=invai-gate-<run id> marks every connection the suite makes; a sampler
#     lists any other application name connected to the gate's database while it runs.

GATE_PG_CONTAINER="${GATE_PG_CONTAINER:-local-postgres-1}"
GATE_VALKEY_CONTAINER="${GATE_VALKEY_CONTAINER:-local-valkey-1}"
GATE_TEST_DB_PREFIX=invai_test_gate_
GATE_TEST_DB_CREATED=0
GATE_WATCH_PID=""
GATE_WATCH_FILE=""

# GATE_RUN_ID: unique per gate process (UTC stamp + pid), [0-9_] only; fixed once when sourced so
# every call in one run agrees on the name.
GATE_RUN_ID="${GATE_RUN_ID:-$(date -u +%Y%m%d%H%M%S)_$$}"
gate_run_id() { echo "$GATE_RUN_ID"; }
gate_test_db_name() { echo "${GATE_TEST_DB_PREFIX}$(gate_run_id)"; }
gate_app_name() { echo "invai-gate-$(gate_run_id)"; }

# gate_test_db_valid <name>: exactly a name this file would make. Every create and drop checks it,
# so invai_test, invai_test_tpl, invai_test_<pid>, invai_gate and the dev DB can never be touched.
gate_test_db_valid() {
  printf '%s' "$1" | grep -Eq '^invai_test_gate_[0-9]{14}_[0-9]+$'
}

# gate_psql_admin <sql>: one statement as the owner on the maintenance database (tests replace it).
gate_psql_admin() {
  docker exec "$GATE_PG_CONTAINER" psql -U invai -d postgres -v ON_ERROR_STOP=1 -Atc "$1"
}

gate_test_db_create() {
  local name="$1"
  gate_test_db_valid "$name" || { log "refused to create '$name': not a gate test database name"; return 1; }
  gate_psql_admin "create database $name owner invai" >>"$LOG_FILE" 2>&1 || return 1
  GATE_TEST_DB_CREATED=1
  gate_psql_admin "grant connect on database $name to invai_app" >>"$LOG_FILE" 2>&1 || return 1
  log "created gate test database $name"
}

# gate_test_db_drop <name>: terminate its sessions, then drop. Safe to call twice.
gate_test_db_drop() {
  local name="$1"
  gate_test_db_valid "$name" || { log "refused to drop '$name': not a gate test database name"; return 1; }
  gate_psql_admin "select pg_terminate_backend(pid) from pg_stat_activity where datname='$name' and pid <> pg_backend_pid()" >>"$LOG_FILE" 2>&1 || true
  if gate_psql_admin "drop database if exists $name" >>"$LOG_FILE" 2>&1; then
    log "dropped gate test database $name"
    GATE_TEST_DB_CREATED=0
    return 0
  fi
  log "could not drop gate test database $name"
  return 1
}

# gate_test_db_drop_leftovers: at gate start, drop gate test databases a killed run left behind.
# Only names that pass gate_test_db_valid are considered, and a database is dropped only when ALL hold:
# its owning gate pid (the last segment of the name) is dead (`kill -0` fails), it has no session at
# all, and its stamp is older than GATE_TEST_DB_STALE_MIN minutes. The stamp is the gate's START time,
# so age alone proves nothing about a long run: a live pid always keeps its database, and sessions of
# a live run are never terminated here.
gate_test_db_drop_leftovers() {
  local stale_min="${GATE_TEST_DB_STALE_MIN:-10}" now cutoff name stamp rows n pid
  rows="$(gate_psql_admin "select d.datname, (select count(*) from pg_stat_activity a where a.datname=d.datname) from pg_database d where d.datname ~ '^invai_test_gate_[0-9]{14}_[0-9]+\$'" 2>>"$LOG_FILE")" || return 0
  now="$(date -u +%s)"
  cutoff=$((now - stale_min * 60))
  while IFS='|' read -r name n; do
    [ -n "$name" ] || continue
    gate_test_db_valid "$name" || continue
    pid="${name##*_}"
    if kill -0 "$pid" 2>/dev/null; then log "left $name alone: its gate (pid $pid) is still running"; continue; fi
    [ "${n:-1}" = 0 ] || { log "left $name alone: it has $n open session(s)"; continue; }
    stamp="${name#$GATE_TEST_DB_PREFIX}"; stamp="${stamp%%_*}"
    if [ "$(gate_stamp_epoch "$stamp")" -lt "$cutoff" ] 2>/dev/null; then
      gate_test_db_drop "$name" || true
    else
      log "left $name alone: younger than $stale_min minutes"
    fi
  done <<EOF
$rows
EOF
}

# gate_stamp_epoch <YYYYMMDDHHMMSS UTC>: epoch seconds (macOS date).
gate_stamp_epoch() { date -u -j -f '%Y%m%d%H%M%S' "$1" +%s 2>/dev/null || echo 0; }

# gate_backend_test_env: the env words (one per line) for the backend `pnpm test`. No name here is
# shared with any other process: not invai_test, not Valkey DB 9 or 15, and no TEST_REDIS_URL, so
# the harness claims a free Valkey DB. REDIS_URL is reset to the DB-0 base URL because the golden
# path's exported .../9 would otherwise be pinned by the harness (pinnedNonZeroRedisUrl).
gate_backend_test_env() {
  local db="$1"
  printf '%s\n' \
    "TEST_DATABASE_URL=postgres://invai_app:invai@localhost:5432/$db" \
    "TEST_MIGRATION_DATABASE_URL=postgres://invai:invai@localhost:5432/$db" \
    "REDIS_URL=redis://localhost:6379" \
    "PGAPPNAME=$(gate_app_name)"
}

# ---------- detection ----------

# gate_foreign_sessions <db> <app>: one "app|addr|state" line per session of another application on <db>.
gate_foreign_sessions() {
  gate_psql_admin "select coalesce(nullif(application_name,''),'(none)')||'|'||coalesce(client_addr::text,'local')||'|'||coalesce(state,'') from pg_stat_activity where datname='$1' and backend_type='client backend' and application_name <> '$2' and pid <> pg_backend_pid()" 2>/dev/null
}

# gate_descendants_from <root pid>: reads "pid ppid" lines on stdin, prints root and all descendants.
gate_descendants_from() {
  awk -v root="$1" '{ kids[$2] = kids[$2] " " $1 } END {
    n = 1; q[1] = root
    for (i = 1; i <= n; i++) { print q[i]; m = split(kids[q[i]], k, " "); for (j = 1; j <= m; j++) q[++n] = k[j] } }'
}

# gate_claim_db_for_pids <pids, space separated>: reads "<lock key> <value>" lines on stdin
# (value "<pid>:<uuid>"); prints the Valkey DB of the first key whose pid is in the list.
gate_claim_db_for_pids() {
  local pids=" $1 " key value pid
  while read -r key value; do
    pid="${value%%:*}"
    case "$pids" in *" $pid "*) echo "${key##*:}"; return 0 ;; esac
  done
  return 1
}

# gate_claim_lines: the harness registry (Valkey DB 15, test-redis-db-lock:<n> = <pid>:<uuid>).
gate_claim_lines() {
  local k v
  docker exec "$GATE_VALKEY_CONTAINER" valkey-cli -n 15 --scan --pattern 'test-redis-db-lock:*' 2>/dev/null | while IFS= read -r k; do
    [ -n "$k" ] || continue
    v="$(docker exec "$GATE_VALKEY_CONTAINER" valkey-cli -n 15 GET "$k" 2>/dev/null)"
    printf '%s %s\n' "$k" "$v"
  done
}

# gate_watch_start <db> <app> <root pid>: sample while the suite runs. Stop with gate_watch_stop.
# The loop ends on a stop file (no kill, so no orphaned sleep).
gate_watch_start() {
  local db="$1" app="$2" root="$3"
  GATE_WATCH_FILE="$(mktemp "${TMPDIR:-/tmp}/gate-watch.XXXXXX")"
  rm -f "$GATE_WATCH_FILE.stop"
  (
    claimed=0
    while [ ! -e "$GATE_WATCH_FILE.stop" ]; do
      gate_foreign_sessions "$db" "$app" | sed 's/^/foreign|/' >>"$GATE_WATCH_FILE"
      if [ "$claimed" = 0 ]; then
        d="$(ps -A -o pid= -o ppid= | gate_descendants_from "$root" | tr '\n' ' ')"
        c="$(gate_claim_lines | gate_claim_db_for_pids "$d")" && { echo "claim|$c" >>"$GATE_WATCH_FILE"; claimed=1; }
      fi
      sleep "${GATE_WATCH_INTERVAL:-1}"
    done
  ) &
  GATE_WATCH_PID=$!
}

# gate_watch_stop: ends the sampler and prints nothing.
gate_watch_stop() {
  [ -n "$GATE_WATCH_PID" ] || return 0
  : >"$GATE_WATCH_FILE.stop"
  wait "$GATE_WATCH_PID" 2>/dev/null || true
  GATE_WATCH_PID=""
}

# gate_harness_valkey_db <suite output>: the Valkey DB the backend test harness says it claimed
# (global-setup.ts prints `[test-redis] claimed Valkey DB <n> ...` at column 0; a backend change to
# that text needs platform-sre, T-51-2). Prints the DB on stdout and returns 0 when exactly one
# claimed DB in 1-8 is named and no pinned-DB line appears. Returns 2 when no claim line is there
# (the caller falls back to the registry sampler), 1 with the reason on stdout when the output
# proves a forbidden state: a DB outside 1-8 (0, 9, 10-14, 15), a `using pinned Valkey DB` line
# (the gate unsets TEST_REDIS_URL, so a pin means the unset failed), or two different claimed DBs.
gate_harness_valkey_db() {
  local out="$1" dbs first
  if printf '%s\n' "$out" | grep -Eq '^\[test-redis\] using pinned Valkey DB'; then
    echo "the suite used a pinned Valkey DB (the gate unsets TEST_REDIS_URL)"; return 1
  fi
  dbs="$(printf '%s\n' "$out" | sed -n 's/^\[test-redis\] claimed Valkey DB \([0-9][0-9]*\)\( .*\)\{0,1\}$/\1/p' | sort -u)"
  [ -n "$dbs" ] || return 2
  if [ "$(printf '%s\n' "$dbs" | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "the harness named two different Valkey DBs ($(printf '%s' "$dbs" | paste -sd, -))"; return 1
  fi
  first="$(printf '%s\n' "$dbs" | head -n1)"
  case "$first" in
    [1-8]) echo "$first"; return 0 ;;
    *) echo "the harness claimed Valkey DB $first, outside the harness range 1-8"; return 1 ;;
  esac
}

# gate_valkey_verdict <suite output> <suite exit code> <registry claim or empty>: logs the
# "gate backend suite Valkey DB" line and returns 0 (proven) or 1 (not proven; reason in
# GATE_VALKEY_REASON). The harness line is the proof; the registry sampler is the fallback and must
# agree with it when both are seen. Neither seen is a failure when the suite itself passed.
gate_valkey_verdict() {
  local out="$1" rc="$2" reg="$3" db hrc
  GATE_VALKEY_REASON=""
  db="$(gate_harness_valkey_db "$out")"; hrc=$?
  if [ $hrc -eq 1 ]; then
    GATE_VALKEY_REASON="$db"; log "gate backend suite Valkey DB: not proven ($db)"; return 1
  fi
  if [ $hrc -eq 0 ]; then
    if [ -n "$reg" ] && [ "$reg" != "$db" ]; then
      GATE_VALKEY_REASON="the harness line says DB $db but the registry claim is DB $reg"
      log "gate backend suite Valkey DB: not proven ($GATE_VALKEY_REASON)"; return 1
    fi
    log "gate backend suite Valkey DB: $db (printed by the test harness${reg:+, registry agrees}; not DB 0, 9 or 15)"
    return 0
  fi
  if [ -n "$reg" ]; then
    case "$reg" in
      [1-8]) log "gate backend suite Valkey DB: $reg (claimed by the test harness; registry only, no harness line in the output; not DB 0, 9 or 15)"; return 0 ;;
      *) GATE_VALKEY_REASON="the registry claim is DB $reg, outside the harness range 1-8"
         log "gate backend suite Valkey DB: not proven ($GATE_VALKEY_REASON)"; return 1 ;;
    esac
  fi
  log "gate backend suite Valkey DB: not observed (no harness line in the output and no claim in the registry)"
  if [ "$rc" -eq 0 ]; then
    GATE_VALKEY_REASON="no harness claim line and no registry claim were seen"; return 1
  fi
  return 0
}

# gate_watch_report <db>: sets GATE_REGISTRY_CLAIM (the sampled Valkey DB, or empty) and logs every foreign session; returns 1 when any
# other application was connected to the gate's database. Removes the sampler files.
gate_watch_report() {
  local db="$1" claim foreign
  claim="$(grep '^claim|' "$GATE_WATCH_FILE" 2>/dev/null | tail -n1 | cut -d'|' -f2)"
  foreign="$(grep '^foreign|' "$GATE_WATCH_FILE" 2>/dev/null | cut -d'|' -f2- | sort | uniq -c | sed 's/^ *//')"
  rm -f "$GATE_WATCH_FILE" "$GATE_WATCH_FILE.stop"
  GATE_REGISTRY_CLAIM="$claim"
  if [ -n "$foreign" ]; then
    log "GATE DETECTION: another application was connected to $db during the suite (count, app|client|state):"
    printf '%s\n' "$foreign" | sed 's/^/  /' >>"$LOG_FILE"
    return 1
  fi
  log "gate detection: no other application connected to $db during the suite"
  return 0
}
