#!/usr/bin/env bash
# The pre-push test gate (T-23-6). Usage: `pnpm gate [repo...]` from invai-infra, or
# `bash scripts/gate.sh [repo...]`. With no repo named, runs on every repo that has commits not
# yet on its origin/main.
#
# - Runs typecheck, lint, the full test suite (and `pnpm build` for web/floor; imaging: ruff +
#   pytest) per repo.
# - If invai-backend, invai-web or invai-floor is in scope, also resets/migrates/seeds the scratch DB
#   invai_gate on Valkey DB 9 (T-41-4; never the dev DB `invai`; imaging up) and runs the API golden path, the browser suite and the floor suite.
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
  gate_scratch_env
fi

log "gate run: repos=${GATE_REPOS[*]} golden_path=$needs_golden_path"

# ---------- preconditions (AC3) ----------

check_preconditions
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
  local img_pgid
  img_pgid="$(start_imaging)"
  STARTED_PIDS+=("$img_pgid")
  if ! wait_http_ok "http://localhost:$IMAGING_PORT/health"; then
    echo "FAIL golden-path imaging: did not come up healthy, see $LOG_FILE"
    GATE_OVERALL_FAILED=1
    return
  fi

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

  section "golden path: browser suite (golden path + screens smoke)"
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

  section "golden path: floor suite"
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
