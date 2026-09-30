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

# ---------- cleanup: stop only what this run started ----------

cleanup() {
  local pid
  for pid in "${STARTED_PIDS[@]:-}"; do
    [ -z "$pid" ] && continue
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

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

# ---------- preconditions (AC3) ----------

# Always checked: a stray process on the test DB/Redis would corrupt any repo's `pnpm test`
# (backend uses both), so this applies regardless of which repos are in scope.
check_preconditions() {
  local n

  n="$(docker exec local-postgres-1 psql -U invai -d invai_test -Atc \
    "select count(*) from pg_stat_activity where datname='invai_test' and pid <> pg_backend_pid()" \
    2>/dev/null || true)"
  if [ -n "$n" ] && [ "$n" != "0" ]; then
    refuse "invai_test has $n open connection(s) from a process this gate did not start; stop it first"
  fi

  n="$(docker exec local-valkey-1 redis-cli client list 2>/dev/null | grep -c 'db=15' || true)"
  if [ -n "$n" ] && [ "$n" != "0" ]; then
    refuse "test Redis (DB 15) has $n open connection(s) from a process this gate did not start; stop it first"
  fi
}

# Only checked when the golden-path phase is about to run its own dev:all on these ports
# (invai-backend/web/floor in scope). A pure typecheck/lint/test run on another repo (invai-ui,
# invai-contracts, invai-imaging, invai-infra) never touches these ports, so it must not be
# blocked by someone else's dev stack or gate run on them.
check_golden_path_ports() {
  local p pid
  for p in 3000 8000 5173 5174; do
    pid="$(lsof -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
    if [ -n "$pid" ]; then
      refuse "port $p is already held by pid $pid (a dev stack this gate did not start); stop it first"
    fi
  done
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
  local extra_env=()
  if [ "$repo" = invai-backend ] && [ "$suite" = test ]; then
    extra_env=(TEST_DATABASE_URL="postgres://invai_app:invai@localhost:5432/invai_test"
               TEST_MIGRATION_DATABASE_URL="postgres://invai:invai@localhost:5432/invai_test"
               TEST_REDIS_URL="redis://localhost:6379/15")
  fi
  if [ "$repo" = invai-web ] || [ "$repo" = invai-floor ]; then
    if [ "$suite" = build ]; then
      extra_env=(VITE_API_URL="${VITE_API_URL:-http://localhost:3000}")
    fi
  fi
  if [ "${#extra_env[@]}" -gt 0 ]; then
    out="$(cd "$WORKSPACE_DIR/$repo" && env "${extra_env[@]}" bash -c "$cmd" 2>&1)"
  else
    out="$(cd "$WORKSPACE_DIR/$repo" && bash -c "$cmd" 2>&1)"
  fi
  rc=$?
  log "$out"
  if [ $rc -eq 0 ]; then
    n="$(count_passed "$out")"
    echo "PASS $repo $suite $n passed"
  else
    names="$(failing_names "$out")"
    [ -z "$names" ] && names="see $LOG_FILE"
    echo "FAIL $repo $suite: $names"
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

# ---------- stamp (AC4) ----------

write_stamp() {
  local repo dir sha now entries=()
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$GATE_DIR"
  for repo in "${GATE_REPOS[@]}"; do
    dir="$WORKSPACE_DIR/$repo"
    sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")"
    [ -z "$sha" ] && continue
    entries+=("\"$repo\":{\"sha\":\"$sha\",\"at\":\"$now\"}")
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
