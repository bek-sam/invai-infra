#!/usr/bin/env bash
# Gate bucket self-check (T-46-2, B-422 / S-83 follow-up). Sourced by gate.sh after cleanup.sh.
#
# The gate's files must land only in invai-gate. After the golden-path seed and again after the floor
# suite (before the end-of-run cleanup deletes the files) it counts, read only, the objects under every
# company id of invai_gate: 0 expected in the dev bucket invai-local, more than 0 in invai-gate. Only the
# s3tool `count` command is used; nothing is created, written or deleted anywhere. The company ids are
# re-read each time, because the E2E suites create companies.

GATE_TOOLS_DIR="${GATE_TOOLS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
GATE_DEV_BUCKET=invai-local

# gate_s3_count <bucket> <prefix>: prints "objects<TAB>bytes" (read only; tests set GATE_S3_TOOL).
gate_s3_count() {
  if [ -n "${GATE_S3_TOOL:-}" ]; then
    S3_BUCKET="$1" "$GATE_S3_TOOL" count "$2"
  else
    S3_BUCKET="$1" node "$GATE_TOOLS_DIR/s3tool.mjs" count "$2"
  fi
}

gate_bucket_check_fail() { # gate_bucket_check_fail <label> <reason>
  echo "FAIL golden-path bucket check ($1): $2"
  GATE_OVERALL_FAILED=1
  return 1
}

# gate_bucket_landing_check <label>: returns 0 when invai-local holds nothing of the gate and
# invai-gate holds something; otherwise prints one FAIL line, sets GATE_OVERALL_FAILED and returns 1.
gate_bucket_landing_check() {
  local label="$1" ids id out n local_n=0 gate_n=0 seen=0
  if ! ids="$(gate_company_ids "$GATE_DB_NAME")" || [ -z "$ids" ]; then
    gate_bucket_check_fail "$label" "cannot read the company ids of $GATE_DB_NAME"
    return 1
  fi
  for id in $ids; do
    gate_valid_prefix "$id/" || continue
    seen=$((seen + 1))
    if ! out="$(gate_s3_count "$GATE_DEV_BUCKET" "$id/" 2>>"$LOG_FILE")"; then
      gate_bucket_check_fail "$label" "cannot count $id/ in $GATE_DEV_BUCKET"
      return 1
    fi
    n="${out%%$'\t'*}"
    case "$n" in '' | *[!0-9]*) gate_bucket_check_fail "$label" "unreadable count for $id/ in $GATE_DEV_BUCKET"; return 1 ;; esac
    local_n=$((local_n + n))
    if ! out="$(gate_s3_count "$GATE_S3_BUCKET" "$id/" 2>>"$LOG_FILE")"; then
      gate_bucket_check_fail "$label" "cannot count $id/ in $GATE_S3_BUCKET"
      return 1
    fi
    n="${out%%$'\t'*}"
    case "$n" in '' | *[!0-9]*) gate_bucket_check_fail "$label" "unreadable count for $id/ in $GATE_S3_BUCKET"; return 1 ;; esac
    gate_n=$((gate_n + n))
  done
  if [ "$seen" -eq 0 ]; then
    gate_bucket_check_fail "$label" "no valid company id in $GATE_DB_NAME"
    return 1
  fi
  if [ "$local_n" -ne 0 ]; then
    gate_bucket_check_fail "$label" "$local_n objects under gate company prefixes in $GATE_DEV_BUCKET (expected 0); files went to the dev bucket"
    return 1
  fi
  if [ "$gate_n" -le 0 ]; then
    gate_bucket_check_fail "$label" "no objects under gate company prefixes in $GATE_S3_BUCKET (expected more than 0)"
    return 1
  fi
  log "gate bucket check ($label): $gate_n objects in $GATE_S3_BUCKET, 0 in $GATE_DEV_BUCKET for $seen companies"
  return 0
}
