#!/usr/bin/env bash
# Shared helpers for scripts/gate.sh (T-23-6). Sourced, not run directly.
#
# Every function that produces user-visible output writes to LOG_FILE (full detail) or, for the
# handful of lines the card allows on stdout, echoes exactly one line. Refusals and internal
# progress go to stderr / the log, never stdout, so `pnpm gate`'s stdout stays to the PASS/FAIL
# lines plus the final "log: <path>" line (AC2).

GATE_OVERALL_FAILED=0
STARTED_PIDS=()

log() { printf '%s\n' "$*" >>"$LOG_FILE"; }
section() { printf '\n==> %s\n' "$*" >>"$LOG_FILE"; }

refuse() {
  echo "GATE REFUSED: $1" >&2
  exit 1
}

# ---------- process groups (T-23-6 r2 finding 3) ----------
#
# `pnpm dev:all` -> `bash dev.sh` -> `exec concurrently` -> api/worker/imaging/web/floor are all
# descendants of the one subshell we background in start_dev_all. A plain `kill $pid` only
# reaches that subshell; the rest of the tree survives and keeps holding
# :3000/:8000/:5173/:5174 (proven by simulation: killing just the parent PID left 3 of 3
# processes running). `set -m` (job control) makes bash give a backgrounded job its own process
# group, whose id equals its own pid ($!); signalling the *negative* pid then reaches every
# process in that group. macOS has no `setsid`, so this - not a `perl -e 'setpgrp; ...'` wrapper -
# is the portable way to get one here.

start_dev_all() {
  local was_m=0
  case $- in *m*) was_m=1 ;; esac
  set -m
  # B-388: INVAI_NO_WATCH=1 makes dev.sh start api, worker and imaging without file watchers, so an
  # edit made while the gate runs cannot restart them mid-suite.
  (cd "$INFRA_DIR" && INVAI_NO_WATCH=1 pnpm dev:all) >>"$LOG_FILE" 2>&1 &
  local pgid=$!
  [ "$was_m" -eq 1 ] || set +m
  echo "$pgid"
}

# start_imaging: imaging alone, in its own process group, for the golden-path seed (the seed
# renders real art through it). Prints the group id. No api/worker may run during reset/seed
# (B-321/B-317: a live worker races the seed's market.sweep).
start_imaging() {
  local was_m=0
  case $- in *m*) was_m=1 ;; esac
  set -m
  (cd "$WORKSPACE_DIR/invai-imaging" && uv run uvicorn app.main:app --host 127.0.0.1 --port "$IMAGING_PORT") >>"$LOG_FILE" 2>&1 &
  local pgid=$!
  [ "$was_m" -eq 1 ] || set +m
  echo "$pgid"
}

# stop_group <pgid>: TERM then KILL the *group*, never a lone pid, and only a group this run
# started (STARTED_PIDS only ever holds pgids from start_dev_all).
stop_group() {
  local pgid="$1" i
  [ -z "$pgid" ] && return 0
  kill -0 "$pgid" 2>/dev/null || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$pgid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pgid" 2>/dev/null || return 0
    sleep 0.5
  done
  kill -KILL -- "-$pgid" 2>/dev/null || kill -KILL "$pgid" 2>/dev/null || true
}

# remove_started_pid <pgid>: drop one id from STARTED_PIDS (bash 3.2 has no easy "remove by
# value" for arrays; `${arr[@]/pat/}` blanks rather than removes and can mangle other numeric
# entries by substring, so rebuild the array instead).
remove_started_pid() {
  local target="$1" kept=() p
  for p in "${STARTED_PIDS[@]:-}"; do
    [ -z "$p" ] && continue
    [ "$p" = "$target" ] && continue
    kept+=("$p")
  done
  if [ "${#kept[@]}" -eq 0 ]; then
    STARTED_PIDS=()
  else
    STARTED_PIDS=("${kept[@]}")
  fi
}

# ---------- cleanup: stop only what this run started ----------

cleanup() {
  local pid
  # Put the dev seed-output.json back if a floor swap is in flight (T-41-4); defined in scratch.sh.
  if declare -F gate_restore_dev_seed >/dev/null && [ "${GATE_SEED_SWAPPED:-0}" = 1 ]; then
    gate_restore_dev_seed
  fi
  for pid in "${STARTED_PIDS[@]:-}"; do
    [ -z "$pid" ] && continue
    stop_group "$pid"
  done
  # T-46-1: a run killed mid-suite still stops its sampler and drops its own test database
  # (defined in testdb.sh).
  if declare -F gate_watch_stop >/dev/null; then gate_watch_stop; fi
  if [ "${GATE_TEST_DB_CREATED:-0}" = 1 ] && declare -F gate_test_db_drop >/dev/null; then
    gate_test_db_drop "$(gate_test_db_name)" || true
  fi
  # T-42-2: with the stack stopped, remove this run's files and flush the scratch Valkey DB
  # (defined in cleanup.sh; armed by gate.sh once the golden-path phase starts).
  if [ "${GATE_CLEANUP_ARMED:-0}" = 1 ] && declare -F gate_cleanup_run >/dev/null; then
    GATE_CLEANUP_ARMED=0
    gate_cleanup_run end
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------- repo/suite catalogue (mirrors .claude/hooks/invai_hooklib.py required_checks) ----------

ALL_REPOS=(invai-contracts invai-ui invai-backend invai-web invai-floor invai-imaging invai-infra)

repo_kind() {
  case "$1" in
    invai-contracts) echo contracts ;;
    invai-ui) echo ui ;;
    invai-backend) echo backend ;;
    invai-web) echo web ;;
    invai-floor) echo floor ;;
    invai-imaging) echo imaging ;;
    invai-infra) echo infra ;;
    *) echo "" ;;
  esac
}

# Space-separated suite list for a repo kind, in run order.
required_checks() {
  case "$1" in
    imaging) echo "lint test" ;;
    infra) echo "typecheck lint" ;;
    web|floor) echo "typecheck lint test build" ;;
    *) echo "typecheck lint test" ;;
  esac
}

check_command() {
  local kind="$1" check="$2"
  case "$kind" in
    imaging)
      case "$check" in
        lint) echo "uv run ruff check ." ;;
        test) echo "uv run pytest" ;;
      esac
      ;;
    *)
      case "$check" in
        typecheck) echo "pnpm typecheck" ;;
        lint) echo "pnpm lint" ;;
        test) echo "pnpm test" ;;
        build) echo "pnpm build" ;;
      esac
      ;;
  esac
}

# ---------- default repo selection: commits not yet on origin/main ----------

default_repos() {
  local repo dir ahead
  for repo in "${ALL_REPOS[@]}"; do
    dir="$WORKSPACE_DIR/$repo"
    [ -d "$dir/.git" ] || continue
    if git -C "$dir" rev-parse --verify origin/main >/dev/null 2>&1; then
      ahead="$(git -C "$dir" rev-list origin/main..HEAD --count 2>/dev/null || echo 1)"
    else
      ahead=1 # no local origin/main ref: be safe and include it
    fi
    if [ "$ahead" != "0" ]; then
      echo "$repo"
    fi
  done
}

# ---------- start-of-run SHA capture + dirty-tree refusal (T-23-6 r2 finding 4) ----------
#
# Populates the global START_SHAS array, one entry per GATE_REPOS at the same index, so
# write_stamp can refuse to record a commit that never actually finished the run: a commit made
# to a repo *during* the run (HEAD moved) or a tracked-file edit left uncommitted (tree dirty at
# the end), either one before the run's own read of HEAD at the end.
check_clean_and_capture_shas() {
  local r dir dirty
  START_SHAS=()
  for r in "${GATE_REPOS[@]}"; do
    dir="$WORKSPACE_DIR/$r"
    dirty="$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null || echo x)"
    if [ -n "$dirty" ]; then
      refuse "$r has uncommitted tracked changes; commit them first (gating a dirty tree could stamp a commit that was never fully tested)"
    fi
    START_SHAS+=("$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")")
  done
}

# ---------- preconditions (AC3) ----------

# Always checked. T-46-1: the backend suite no longer uses the shared names `invai_test` and Valkey
# DB 15 (other agents' vitest runs use them legitimately, DB 15 is the harness claim registry), so
# those two checks are gone. What the gate will use instead is checked: its own database name must
# not exist or have a session (a stray holder of a name only this run knows), and the name must
# be a valid gate name.
check_preconditions() {
  local n db
  db="$(gate_test_db_name)"
  gate_test_db_valid "$db" || refuse "gate test database name '$db' is not a valid gate name"
  n="$(gate_psql_admin "select count(*) from pg_stat_activity where datname='$db'" 2>/dev/null || true)"
  if [ -n "$n" ] && [ "$n" != "0" ]; then
    refuse "$db has $n open connection(s) from a process this gate did not start; stop it first"
  fi
  n="$(gate_psql_admin "select 1 from pg_database where datname='$db'" 2>/dev/null || true)"
  if [ "$n" = 1 ]; then
    refuse "$db already exists; this run's test database name must be new"
  fi
}

# Only checked when the golden-path phase is about to run its own dev:all on the configured ports
# (INVAI_*_PORT, default 3000/8000/5173/5174)
# (invai-backend/web/floor in scope). A pure typecheck/lint/test run on another repo (invai-ui,
# invai-contracts, invai-imaging, invai-infra) never touches these ports, so it must not be
# blocked by someone else's dev stack or gate run on them.
check_golden_path_ports() {
  local msg
  if msg="$(first_busy_port_message)"; then
    refuse "$msg"
  fi
}

# ---------- running one suite ----------

# Extracts "<n> passed" style counts from captured output; falls back to 1 on success, 0 on failure.
count_passed() {
  local out="$1" n
  n="$(printf '%s' "$out" | grep -Eo '[0-9]+ passed' | tail -1 | grep -Eo '[0-9]+' || true)"
  [ -n "$n" ] && { echo "$n"; return; }
  n="$(printf '%s' "$out" | grep -Eo 'Checked [0-9]+ files' | grep -Eo '[0-9]+' | head -1 || true)"
  [ -n "$n" ] && { echo "$n"; return; }
  echo 1
}

failing_names() {
  local out="$1"
  printf '%s' "$out" | grep -E '^\s*(FAIL|×|✗|FAILED) ' | sed 's/^\s*//' | head -8 | paste -sd'; ' -
}

# run_suite <repo> <suite>
run_suite() {
  local repo="$1" suite="$2" kind out rc cmd n names
  kind="$(repo_kind "$repo")"
  cmd="$(check_command "$kind" "$suite")"
  section "$repo $suite: $cmd"
  local extra_env=() env_cmd=(env) tdb="" tapp="" watch_rc=0 hint="" valkey_rc=0
  if [ "$repo" = invai-backend ] && [ "$suite" = test ]; then
    # T-46-1: a database and (via the harness claim) a Valkey DB no other process names.
    tdb="$(gate_test_db_name)"; tapp="$(gate_app_name)"
    log "gate backend suite: database $tdb (created by this run, pinned, dropped at the end), PGAPPNAME $tapp, Valkey DB claimed by the harness (REDIS_URL reset to the DB 0 base URL, no TEST_REDIS_URL)"
    if ! gate_test_db_create "$tdb"; then
      echo "FAIL $repo $suite: could not create the gate test database $tdb, see $LOG_FILE"
      GATE_OVERALL_FAILED=1
      gate_test_db_drop "$tdb" || true
      return
    fi
    while IFS= read -r line; do extra_env+=("$line"); done < <(gate_backend_test_env "$tdb")
    env_cmd=(env -u TEST_REDIS_URL)
    gate_watch_start "$tdb" "$tapp" "$$"
  fi
  if [ "$repo" = invai-web ] || [ "$repo" = invai-floor ]; then
    if [ "$suite" = build ]; then
      extra_env=(VITE_API_URL="${VITE_API_URL:-http://localhost:$API_PORT}")
    fi
  fi
  if [ "${#extra_env[@]}" -gt 0 ]; then
    out="$(cd "$WORKSPACE_DIR/$repo" && "${env_cmd[@]}" "${extra_env[@]}" bash -c "$cmd" 2>&1)"
  else
    out="$(cd "$WORKSPACE_DIR/$repo" && bash -c "$cmd" 2>&1)"
  fi
  rc=$?
  log "$out"
  if [ -n "$tdb" ]; then
    gate_watch_stop
    gate_watch_report "$tdb" || { watch_rc=1; hint=" [another application connected to $tdb during the suite, see $LOG_FILE]"; }
    # T-51-2 (B-436): the Valkey DB is proven from the suite's own output; the sampler is the fallback.
    gate_valkey_verdict "$out" "$rc" "$GATE_REGISTRY_CLAIM" || valkey_rc=1
    gate_test_db_drop "$tdb" || true
  fi
  if [ $rc -eq 0 ] && [ "$valkey_rc" -ne 0 ]; then
    echo "FAIL $repo $suite: Valkey DB not proven ($GATE_VALKEY_REASON), see $LOG_FILE"
    GATE_OVERALL_FAILED=1
  elif [ $rc -eq 0 ]; then
    n="$(count_passed "$out")"
    echo "PASS $repo $suite $n passed"
  else
    names="$(failing_names "$out")"
    [ -z "$names" ] && names="see $LOG_FILE"
    [ "$valkey_rc" -eq 0 ] || hint="$hint [Valkey DB not proven: $GATE_VALKEY_REASON]"
    echo "FAIL $repo $suite: $names$hint"
    GATE_OVERALL_FAILED=1
  fi
  [ "$watch_rc" -eq 0 ] || [ $rc -ne 0 ] || echo "WARN $repo $suite passed, but another application was connected to $tdb during it, see $LOG_FILE" >&2
}

# run_contracts_check: after invai-contracts' own suites, typecheck backend/web/floor/ui against
# the contracts tree under test (T-32-4). One PASS/FAIL line like run_suite; WARN lines (changelog)
# go to the log only.
run_contracts_check() {
  local out rc names
  section "invai-contracts consumers: bash scripts/contracts-check.sh"
  out="$(bash "$INFRA_DIR/scripts/contracts-check.sh" --contracts "$WORKSPACE_DIR/invai-contracts" 2>&1)"
  rc=$?
  log "$out"
  if [ $rc -eq 0 ]; then
    echo "PASS invai-contracts consumers $(printf '%s\n' "$out" | grep -c '^PASS ') passed"
  else
    names="$(printf '%s\n' "$out" | grep -E '^FAIL ' | sed 's/ (contracts.*//; s/^FAIL //' | paste -sd',' -)"
    [ -z "$names" ] && names="setup error, see $LOG_FILE"
    echo "FAIL invai-contracts consumers: $names"
    GATE_OVERALL_FAILED=1
  fi
}

# ---------- infra health (for the golden-path phase) ----------

wait_healthy() {
  local container="local-$1-1" tries=60 i status
  for ((i = 0; i < tries; i++)); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)"
    [ "$status" = healthy ] && return 0
    sleep 1
  done
  return 1
}

wait_http_ok() {
  local url="$1" tries=60 i
  for ((i = 0; i < tries; i++)); do
    curl -sf -o /dev/null "$url" && return 0
    sleep 1
  done
  return 1
}

# ---------- stamp (AC4, T-23-6 r2 finding 4) ----------
#
# Stamps a repo only if its HEAD at the end still equals the START_SHAS entry captured before
# any suite ran, and its tracked tree is still clean: a commit or edit mid-run means the tree the
# suites actually tested is not the tree at the end, so there is nothing honest to stamp.

write_stamp() {
  local repo dir sha now entries=() i=0 dirty
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$GATE_DIR"
  for repo in "${GATE_REPOS[@]}"; do
    dir="$WORKSPACE_DIR/$repo"
    sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")"
    dirty="$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null || echo x)"
    if [ -z "$sha" ] || [ "$sha" != "${START_SHAS[$i]:-}" ] || [ -n "$dirty" ]; then
      log "not stamping $repo: the tree changed during the run (start sha ${START_SHAS[$i]:-<none>}, end sha ${sha:-<none>}${dirty:+, dirty at end})"
      i=$((i + 1))
      continue
    fi
    entries+=("\"$repo\":{\"sha\":\"$sha\",\"at\":\"$now\"}")
    i=$((i + 1))
  done
  {
    printf '{"repos":{'
    local i first=1
    for i in "${entries[@]:-}"; do
      [ -z "$i" ] && continue
      [ $first -eq 0 ] && printf ','
      printf '%s' "$i"
      first=0
    done
    printf '},"at":"%s"}\n' "$now"
  } >"$STAMP_FILE.tmp"
  mv "$STAMP_FILE.tmp" "$STAMP_FILE"
  log "wrote stamp $STAMP_FILE"
}

# ---------- local rate-limit buckets (T-36-5, B-350) ----------
#
# The product's token buckets live in the local dev Valkey as `tb:<bucket>:<companyId>`. The web
# suite leaves the demo shop's `reads` bucket part-empty, so the floor suite right after it can
# get RATE_LIMITED. Like the DB reset, each E2E suite starts from fresh buckets. Only `tb:*` keys
# in the one DB the gate stack uses (Valkey DB 9, T-41-4) are deleted (SCAN, never KEYS/FLUSH*), and only through the
# local container. Result: prints "deleted N" on stdout, returns 0; on refusal prints a reason on
# stdout and returns 1.
GATE_VALKEY_CONTAINER="${GATE_VALKEY_CONTAINER:-local-valkey-1}"

reset_rate_buckets() {
  local url="${GATE_REDIS_URL:-${REDIS_URL:-redis://localhost:6379}}"
  local rest hostport host db
  case "$url" in
    redis://*) rest="${url#redis://}" ;;
    *) echo "refused: target '$url' is not a redis:// URL"; return 1 ;;
  esac
  rest="${rest#*@}"
  hostport="${rest%%/*}"
  host="${hostport%%:*}"
  db=0
  case "$rest" in */*) db="${rest#*/}"; db="${db%%\?*}" ;; esac
  [ -z "$db" ] && db=0
  case "$host" in
    localhost | 127.0.0.1) ;;
    *) echo "refused: target host '$host' is not local"; return 1 ;;
  esac
  case "$db" in
    '' | *[!0-9]*) echo "refused: DB '$db' is not a number"; return 1 ;;
  esac
  if [ "$db" -eq 15 ]; then
    echo "refused: DB 15 is the test harness's claim registry"
    return 1
  fi
  if [ "$db" -eq 0 ]; then
    echo "refused: DB 0 is the dev Valkey DB"
    return 1
  fi
  local keys_file n
  keys_file="$(mktemp)"
  if ! docker exec "$GATE_VALKEY_CONTAINER" valkey-cli -n "$db" --scan --pattern 'tb:*' >"$keys_file" 2>/dev/null; then
    rm -f "$keys_file"
    echo "refused: cannot reach container $GATE_VALKEY_CONTAINER"
    return 1
  fi
  n=0
  local key
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    docker exec "$GATE_VALKEY_CONTAINER" valkey-cli -n "$db" UNLINK "$key" >/dev/null 2>&1 && n=$((n + 1))
  done <"$keys_file"
  rm -f "$keys_file"
  echo "deleted $n"
  return 0
}

# Gate step: runs reset_rate_buckets before one E2E suite; a refusal fails the golden-path step.
gate_reset_buckets_for() {
  local suite="$1" out
  if out="$(reset_rate_buckets)"; then
    log "rate buckets reset before $suite: $out tb:* keys"
    return 0
  fi
  echo "FAIL golden-path rate-limit reset before $suite: $out"
  GATE_OVERALL_FAILED=1
  return 1
}

# gate_full_profile_running: prints the running compose `full` profile containers (they use Valkey
# DB 9 too, local/docker-compose.yml) and returns 0 when there is at least one (T-42-2 round 2).
# A docker that cannot answer counts as "running": no answer is never read as "all clear".
gate_full_profile_running() {
  local names
  if ! names="$(docker ps --format '{{.Names}}' 2>/dev/null)"; then echo "docker did not answer"; return 0; fi
  names="$(printf '%s\n' "$names" | grep -E '^local-(full-db-init|migrate|api|worker|imaging|web|floor)-1$' || true)"
  [ -n "$names" ] || return 1
  printf '%s\n' "$names" | tr '\n' ' '
  return 0
}
