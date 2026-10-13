#!/usr/bin/env bash
# Tests for the gate's post-seed and end-of-run bucket check (T-46-2, AC4/A4). bash 3.2 compatible.
# No database, Valkey or MinIO is touched: company ids and the s3 helper are stubbed. GATE_SRC_DIR
# points at a copy of scripts/ to prove a removed or always-passing check goes red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${GATE_SRC_DIR:-$(cd "$HERE/.." && pwd)}"
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
export GATE_PG_CONTAINER=no-such-pg-container GATE_VALKEY_CONTAINER=no-such-valkey-container
export S3_ENDPOINT=http://127.0.0.1:1
unset GATE_S3_TOOL PURGE_S3_TOOL
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
A=11111111-1111-4111-8111-111111111111; B=22222222-2222-4222-8222-222222222222

# the s3 helper stub: "count <prefix>" under $S3_BUCKET; table lines "bucket prefix objects"
cat >"$T/tool.sh" <<'TOOL'
#!/bin/sh
echo "S3_BUCKET=$S3_BUCKET $*" >>"$TOOLLOG"
[ -n "${TOOLFAIL:-}" ] && exit 1
[ "$1" = count ] || exit 9
n="$(awk -v b="$S3_BUCKET" -v p="$2" '$1==b && $2==p {s+=$3} END {print s+0}' "$TABLE")"
printf '%s\t%s\n' "$n" 0
TOOL
chmod +x "$T/tool.sh"

# chk <label> <ids> <table content> [TOOLFAIL]: sets RC, OUT, OVERALL, CALLS
chk() {
  : >"$T/calls"; : >"$T/log"; printf '%s\n' "$3" >"$T/table"
  OUT="$( ( export LOG_FILE="$T/log" GATE_DIR="$T" WORKSPACE_DIR="$T" INFRA_DIR="$T" TOOLLOG="$T/calls" TABLE="$T/table" TOOLFAIL="${4:-}" GATE_S3_TOOL="$T/tool.sh" IDS="$2"
    source "$SRC/gate/lib.sh"; source "$SRC/gate/scratch.sh"; source "$SRC/gate/cleanup.sh"; source "$SRC/gate/bucketcheck.sh"
    GATE_OVERALL_FAILED=0
    gate_company_ids() { [ "$1" = invai_gate ] || return 1; [ -n "${IDS:-}" ] && printf '%s\n' $IDS; [ "${IDS:-x}" != UNREADABLE ]; }
    gate_bucket_landing_check "$1"; echo "rc=$? overall=$GATE_OVERALL_FAILED" ) 2>&1 )"
  RC="$(printf '%s' "$OUT" | sed -n 's/.*rc=\([0-9]*\) overall=.*/\1/p')"; OVERALL="${OUT##*overall=}"; CALLS="$(cat "$T/calls")"
}

chk "after seed" "$A $B" "invai-gate $A/ 40
invai-gate $B/ 12"
eq "files only in invai-gate: passes" "$RC|$OVERALL" "0|0"
case "$OUT" in *FAIL*) bad "no FAIL line on a pass ($OUT)" ;; *) ok "no FAIL line on a pass" ;; esac
eq "every call is a read-only count" "$(printf '%s\n' "$CALLS" | grep -vc ' count ')" 0
eq "both buckets and both companies are counted (4 calls)" "$(printf '%s\n' "$CALLS" | grep -c .)" 4
case "$CALLS" in *"S3_BUCKET=invai-local count $A/"*) ok "invai-local is counted per gate company prefix" ;; *) bad "invai-local counted ($CALLS)" ;; esac

chk "after seed" "$A $B" "invai-gate $A/ 40
invai-local $B/ 3"
eq "one file in invai-local: fails" "$RC|$OVERALL" "1|1"
case "$OUT" in *"FAIL golden-path bucket check (after seed): 3 objects"*"invai-local"*) ok "one clear FAIL line names the dev bucket and the count" ;; *) bad "FAIL line ($OUT)" ;; esac
eq "the FAIL is one line" "$(printf '%s\n' "$OUT" | grep -c '^FAIL')" 1

chk "after seed" "$A" "invai-local $A/ 1
invai-gate $A/ 0"
eq "objects in both buckets: fails (invai-local must be empty)" "$RC|$OVERALL" "1|1"
chk "end of run" "$A $B" "invai-gate $A/ 0
invai-gate $B/ 0"
eq "nothing in invai-gate: fails" "$RC|$OVERALL" "1|1"
case "$OUT" in *"(end of run)"*"invai-gate"*) ok "the FAIL line carries the label and the gate bucket" ;; *) bad "empty-gate FAIL line ($OUT)" ;; esac
chk "after seed" "" "invai-gate $A/ 5"
eq "no company ids: fails" "$RC|$OVERALL" "1|1"
chk "after seed" "UNREADABLE" "invai-gate $A/ 5"
eq "unreadable company ids: fails" "$RC|$OVERALL" "1|1"
chk "after seed" "$A" "invai-gate $A/ 5" 1
eq "a failing count tool is a failure, never a pass" "$RC|$OVERALL" "1|1"
chk "after seed" "not-a-uuid" "invai-gate not-a-uuid/ 5"
eq "an id that is not a UUID is not counted and fails (nothing checked)" "$RC|$OVERALL" "1|1"

# A4: the ids are re-read each time (E2E creates companies): a company only the second check sees
chk "after seed" "$A" "invai-gate $A/ 5"
eq "first check (one company) passes" "$RC" 0
chk "end of run" "$A $B" "invai-gate $A/ 5
invai-local $B/ 7"
eq "the company created later is checked and its file in invai-local fails the end-of-run check" "$RC|$OVERALL" "1|1"

# same process, two checks, ids changing in between (the real gate): the second check re-reads the ids
printf 'invai-gate %s/ 5\ninvai-local %s/ 7\n' "$A" "$B" >"$T/table"; : >"$T/calls"; : >"$T/log"
OUT="$( ( export LOG_FILE="$T/log" GATE_DIR="$T" WORKSPACE_DIR="$T" INFRA_DIR="$T" TOOLLOG="$T/calls" TABLE="$T/table" GATE_S3_TOOL="$T/tool.sh" IDS="$A"
  source "$SRC/gate/lib.sh"; source "$SRC/gate/scratch.sh"; source "$SRC/gate/cleanup.sh"; source "$SRC/gate/bucketcheck.sh"
  GATE_OVERALL_FAILED=0
  gate_company_ids() { printf '%s\n' $IDS; }
  gate_bucket_landing_check "after seed"; r1=$?; IDS="$A $B"; gate_bucket_landing_check "end of run"; r2=$?
  echo "r1=$r1 r2=$r2" ) 2>&1 )"
case "$OUT" in *"r1=0 r2=1") ok "the end-of-run check re-reads the company ids (E2E created a company) and catches it" ;; *) bad "re-read of company ids ($OUT)" ;; esac

# static: gate.sh runs the check after the seed and after the floor suite, before the EXIT cleanup
G="$SRC/gate.sh"
ln() { grep -n "$1" "$G" | head -n1 | cut -d: -f1; }
seed="$(ln 'pnpm db:seed')"; c1="$(ln 'gate_bucket_landing_check "after seed" || return')"; stopimg="$(ln 'stop_group "\$img_pgid"')"
[ -n "$seed" ] && [ -n "$c1" ] && [ -n "$stopimg" ] && [ "$seed" -lt "$c1" ] && [ "$c1" -lt "$stopimg" ] && ok "post-seed check runs after the seed and before the stack starts" || bad "post-seed check position ($seed $c1 $stopimg)"
floor="$(ln 'FAIL invai-floor e2e')"; c2="$(ln 'gate_bucket_landing_check "end of run"')"; stamp="$(ln 'write_stamp')"
[ -n "$floor" ] && [ -n "$c2" ] && [ -n "$stamp" ] && [ "$floor" -lt "$c2" ] && [ "$c2" -lt "$stamp" ] && ok "end-of-run check runs after the floor suite, before the stamp" || bad "end-of-run check position ($floor $c2 $stamp)"
grep -q 'gate_cleanup_run end' "$SRC/gate/lib.sh" && ok "the end cleanup (files deleted) stays in the EXIT trap, after the run function returns" || bad "end cleanup in the EXIT trap"
grep -q 'source "\$SCRIPT_DIR/gate/bucketcheck.sh"' "$G" && ok "gate.sh sources bucketcheck.sh" || bad "gate.sh sources bucketcheck.sh"
# static: the check only counts
if grep -Eq 'delete-prefix|ensure-bucket|DeleteObject|CreateBucket|PutObject' "$SRC/gate/bucketcheck.sh"; then bad "bucketcheck.sh is read only"; else ok "bucketcheck.sh is read only (count only)"; fi
exit $fail
