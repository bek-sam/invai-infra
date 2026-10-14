#!/usr/bin/env bash
# The pre-push test gate (T-23-6). Usage: `pnpm gate [repo...]` from invai-infra, or
# `bash scripts/gate.sh [repo...]`. With no repo named, runs on every repo that has commits not
# yet on its origin/main.
#
# - Runs typecheck, lint, the full test suite (and `pnpm build` for web/floor; imaging: ruff +
#   pytest) per repo.
# - If invai-backend, invai-web or invai-floor is in scope, also resets/migrates/seeds the scratch DB
#   invai_gate on Valkey DB 9 (T-41-4; never the dev DB `invai`; imaging up) and runs the API golden path, the browser suite and the floor suite.
# - Checks, read only, after the seed and after the floor suite that its files are in invai-gate and none
#   in invai-local (T-46-2); a miss fails the run.
# - Compares the Docker VM clock with the Mac clock at the start and between suites; a skew over 10 s
#   (or an unreadable clock) ends the run with one FAIL line and no stamp (T-55-4, gate/clock.sh).
# - Removes its own MinIO files (every company in invai_gate) and flushes Valkey DB 9 at the end of
#   every run and, for a run killed without its trap, at the start of the next (T-42-2).
# - Starts api, worker and imaging without file watchers (B-388).
# - Refuses to start rather than fight another process (AC3); never kills anything it didn't
#   start (trap in lib.sh stops only PIDs this run recorded).
# - On a full pass, writes invai-infra/.gate/pass.json (gitignored) with each repo's HEAD SHA and
#   a time; guard-bash.py checks this stamp before allowing a push to main.
#
# stdout carries only PASS/FAIL lines and the final "log: <path>" line (AC2); everything else
# (docker waits, refusal reasons) goes to the log file or stderr.
set -uo pipefail

export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/share/pnpm:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$INFRA_DIR/.." && pwd)"
GATE_DIR="$INFRA_DIR/.gate"
STAMP_FILE="$GATE_DIR/pass.json"
mkdir -p "$GATE_DIR"
LOG_FILE="$GATE_DIR/run-$(date -u +%Y%m%dT%H%M%SZ).log"
: >"$LOG_FILE"

# shellcheck source=gate/lib.sh
source "$SCRIPT_DIR/gate/lib.sh"
# shellcheck source=gate/ports.sh
source "$SCRIPT_DIR/gate/ports.sh"
# shellcheck source=gate/scratch.sh
source "$SCRIPT_DIR/gate/scratch.sh"
# shellcheck source=gate/cleanup.sh
source "$SCRIPT_DIR/gate/cleanup.sh"
# shellcheck source=gate/bucketcheck.sh
source "$SCRIPT_DIR/gate/bucketcheck.sh"
# shellcheck source=gate/testdb.sh
source "$SCRIPT_DIR/gate/testdb.sh"
# shellcheck source=gate/clock.sh
source "$SCRIPT_DIR/gate/clock.sh"

# Ports come from INVAI_*_PORT (T-36-1); validate and export before anything starts.
resolve_ports || refuse "$PORT_ERROR"

# ---------- repo selection ----------

if [ "$#" -gt 0 ]; then
  GATE_REPOS=("$@")
else
  # bash 3.2 (the only bash on this machine, see the invai-infra README) has no `mapfile`.
  GATE_REPOS=()
  while IFS= read -r r; do
    [ -n "$r" ] && GATE_REPOS+=("$r")
  done < <(default_repos)
fi

if [ "${#GATE_REPOS[@]}" -eq 0 ]; then
  echo "log: $LOG_FILE"
  log "no repo has commits ahead of origin/main; nothing to do"
  exit 0
fi

for r in "${GATE_REPOS[@]}"; do
  if [ -z "$(repo_kind "$r")" ]; then
    refuse "unknown repo '$r' (expected one of: ${ALL_REPOS[*]})"
  fi
done

# Finding 4: capture each repo's HEAD before anything runs, and refuse outright on a dirty
# tracked tree (the run would be testing something the stamp couldn't honestly describe).
check_clean_and_capture_shas

needs_golden_path=0
for r in "${GATE_REPOS[@]}"; do
  case "$r" in
    invai-backend|invai-web|invai-floor) needs_golden_path=1 ;;
  esac
done

if [ "$needs_golden_path" -eq 1 ]; then
  # A9: a previous run killed with SIGKILL may have left the dev seed-output.json swapped.
  gate_restore_dev_seed
  why="$(gate_refuse_paid_ai)" || refuse "$why in the gate's environment; paid AI spend on $GATE_DB_NAME would escape the dev ledger"
  if who="$(gate_full_profile_running)"; then
    refuse "the compose full profile is running ($who) and shares Valkey DB 9 with the gate; run scripts/full.sh down first"
  fi
  gate_scratch_env
  # T-55-4: a Docker VM clock that drifted from the Mac fails time-based tests (wave 54); stop first.
  gate_clock_check "start"
fi

log "gate run: repos=${GATE_REPOS[*]} golden_path=$needs_golden_path"

# ---------- preconditions (AC3) ----------

check_preconditions
gate_test_db_drop_leftovers
if [ "$needs_golden_path" -eq 1 ]; then
  check_golden_path_ports
fi

# ---------- per-repo checks (AC1, AC2) ----------

for r in "${GATE_REPOS[@]}"; do
  kind="$(repo_kind "$r")"
  for suite in $(required_checks "$kind"); do
    run_suite "$r" "$suite"
  done
  if [ "$r" = invai-contracts ]; then
    run_contracts_check
  fi
  if [ "$needs_golden_path" -eq 1 ]; then
    gate_clock_check "after $r checks"
  fi
done

# ---------- golden path (AC1) ----------

run_golden_path() {
  # Order matters (B-321): nothing but imaging runs while db:reset/migrate/seed run, so no worker
  # holds or races jobs from before the reset. The full dev group starts only after the seed.
  section "golden path: infra, then imaging alone for the seed"
  if ! (cd "$INFRA_DIR/local" && docker compose up -d) >>"$LOG_FILE" 2>&1; then
    echo "FAIL golden-path infra: docker compose up failed, see $LOG_FILE"
    GATE_OVERALL_FAILED=1
    return
  fi
  if ! wait_healthy postgres || ! wait_healthy valkey || ! wait_healthy minio || ! wait_healthy mailpit; then
    echo "FAIL golden-path infra: containers did not become healthy, see $LOG_FILE"
    GATE_OVERALL_FAILED=1
    return
  fi
  # T-45-5: every child below that touches S3 writes to bucket invai-gate, which must exist first.
  gate_bucket_env
  if ! gate_ensure_bucket; then
    echo "FAIL golden-path bucket: could not create bucket $GATE_S3_BUCKET, see $LOG_FILE"
    GATE_OVERALL_FAILED=1
    return
  fi
  local img_pgid
  img_pgid="$(start_imaging)"
  STARTED_PIDS+=("$img_pgid")
  if ! wait_http_ok "http://localhost:$IMAGING_PORT/health"; then
    echo "FAIL golden-path imaging: did not come up healthy, see $LOG_FILE"
    GATE_OVERALL_FAILED=1
    return
  fi

  # T-42-2: files of the previous run's seed (a killed run skips its trap, and the reset below
  # would lose the ids), then arm the end-of-run cleanup that the EXIT trap performs.
  GATE_CLEANUP_ARMED=1
  gate_cleanup_run start

  section "golden path: reset, migrate, seed on $GATE_DB_NAME"
  if ! gate_ensure_db; then
    echo "FAIL golden-path database: could not create $GATE_DB_NAME, see $LOG_FILE"
    GATE_OVERALL_FAILED=1
    return
  fi
  local seed_out seed_rc
  seed_out="$(cd "$WORKSPACE_DIR/invai-backend" && pnpm db:reset && pnpm db:migrate && pnpm db:seed 2>&1)"
  seed_rc=$?
  log "$seed_out"
  if [ $seed_rc -ne 0 ]; then
    echo "FAIL golden-path seed: db:reset/migrate/seed failed, see $LOG_FILE"
    GATE_OVERALL_FAILED=1
    return
  fi

  # T-46-2: the seed's files must be in invai-gate and none in the dev bucket (read-only counts).
  gate_bucket_landing_check "after seed" || return
  gate_clock_check "after seed"

  # Stop the imaging group (own process group), then start the whole stack once. The group is
  # stopped as a group so nothing keeps the imaging port under the new imaging.
  stop_group "$img_pgid"
  remove_started_pid "$img_pgid"

  section "golden path: starting invai-infra pnpm dev:all (after the seed)"
  local dev_pgid
  dev_pgid="$(start_dev_all)"
  STARTED_PIDS+=("$dev_pgid")
  if ! wait_http_ok "http://localhost:$API_PORT/health" || ! wait_http_ok "http://localhost:$IMAGING_PORT/health" \
      || ! wait_http_ok "http://localhost:$WEB_PORT" || ! wait_http_ok "http://localhost:$FLOOR_PORT"; then
    echo "FAIL golden-path startup: api/imaging/web/floor did not come up healthy, see $LOG_FILE"
    GATE_OVERALL_FAILED=1
    return
  fi

  section "golden path: API suite"
  gate_clock_check "before API suite"
  gate_reset_buckets_for "API suite" || return
  local out rc
  out="$(cd "$WORKSPACE_DIR/invai-web" && E2E_API=1 pnpm e2e e2e/api-golden-path.spec.ts 2>&1)"
  rc=$?
  log "$out"
  if [ $rc -eq 0 ]; then
    echo "PASS invai-web api-golden-path $(count_passed "$out") passed"
  else
    echo "FAIL invai-web api-golden-path: $(failing_names "$out")"
    GATE_OVERALL_FAILED=1
  fi
  gate_clock_check "after API suite"

  section "golden path: browser suite (golden path + screens smoke)"
  gate_clock_check "before browser suite"
  gate_reset_buckets_for "browser suite" || return
  out="$(cd "$WORKSPACE_DIR/invai-web" && pnpm e2e 2>&1)"
  rc=$?
  log "$out"
  if [ $rc -eq 0 ]; then
    echo "PASS invai-web e2e $(count_passed "$out") passed"
  else
    echo "FAIL invai-web e2e: $(failing_names "$out")"
    GATE_OVERALL_FAILED=1
  fi
  gate_clock_check "after browser suite"

  section "golden path: floor suite"
  gate_clock_check "before floor suite"
  gate_reset_buckets_for "floor suite" || return
  gate_swap_dev_seed || { echo "FAIL golden-path floor seed swap: see $LOG_FILE"; GATE_OVERALL_FAILED=1; return; }
  out="$(cd "$WORKSPACE_DIR/invai-floor" && pnpm e2e 2>&1)"
  rc=$?
  gate_restore_dev_seed
  log "$out"
  if [ $rc -eq 0 ]; then
    echo "PASS invai-floor e2e $(count_passed "$out") passed"
  else
    echo "FAIL invai-floor e2e: $(failing_names "$out")"
    GATE_OVERALL_FAILED=1
  fi
  gate_clock_check "after floor suite"

  # T-46-2: the suites (api, worker, imaging, E2E-created companies) wrote files too; check again
  # before the EXIT trap's cleanup deletes them.
  gate_bucket_landing_check "end of run"
}

if [ "$needs_golden_path" -eq 1 ]; then
  run_golden_path
fi

# ---------- stamp (AC4) ----------

if [ "$GATE_OVERALL_FAILED" -eq 0 ]; then
  write_stamp
else
  log "gate failed: not writing $STAMP_FILE"
fi

echo "log: $LOG_FILE"
exit "$GATE_OVERALL_FAILED"
