#!/usr/bin/env bash
# Tests for the gate cleanup fences and the no-watch stack (T-42-2). bash 3.2 compatible.
# No database, Valkey or MinIO is touched: docker and the S3 helper are stubbed.
# GATE_SRC_DIR points at a copy of scripts/ to prove a deleted fence goes red.
set -uo pipefail
export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/share/pnpm:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${GATE_SRC_DIR:-$(cd "$HERE/.." && pwd)}"
fail=0
# Hermetic (T-42-2 round 2, incident 2026-10-13): every path that could reach a delete points at a
# dead endpoint and containers that do not exist, so a removed fence fails a test instead of
# deleting. The run aborts unless the endpoint is proven dead first.
export S3_ENDPOINT=http://127.0.0.1:1 S3_BUCKET=invai-gate
export GATE_PG_CONTAINER=no-such-pg-container GATE_VALKEY_CONTAINER=no-such-valkey-container PURGE_PG_CONTAINER=no-such-pg-container
export DATABASE_URL=postgres://nobody:nobody@127.0.0.1:1/no_such_db MIGRATION_DATABASE_URL=postgres://nobody:nobody@127.0.0.1:1/no_such_db REDIS_URL=redis://127.0.0.1:1/9
unset GATE_S3_TOOL PURGE_S3_TOOL
if ! { out="$(node "$SRC/gate/s3tool.mjs" buckets 2>&1)"; [ $? -ne 0 ] && printf '%s' "$out" | grep -qi 'ECONNREFUSED\|connect'; }; then
  echo "ABORT - the test endpoint is not dead; refusing to run (a mutant could delete real files)"; exit 3
fi
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
A=11111111-1111-4111-8111-111111111111; B=22222222-2222-4222-8222-222222222222; L=33333333-3333-4333-8333-333333333333
UP=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA

# run <gate ids> <live ids> <GATE_DB_NAME> -> sets RC, CALLS (s3 calls), LOGTXT
run() {
  : >"$T/calls"; : >"$T/log"
  ( export LOG_FILE="$T/log" GATE_DIR="$T" WORKSPACE_DIR="$T" INFRA_DIR="$T"
    source "$SRC/gate/lib.sh"; source "$SRC/gate/scratch.sh"; source "$SRC/gate/cleanup.sh"
    GATE_DB_NAME="${3:-invai_gate}"
    gate_company_ids() { if [ "$1" = invai ]; then printf '%s\n' $L_IDS; else printf '%s\n' $G_IDS; fi; }
    gate_s3() { echo "$*" >>"$T/calls"; printf '3\t300\n'; }
    G_IDS="$1" L_IDS="$2"
    gate_cleanup_files test; echo "$?" >"$T/rc" ) 2>/dev/null
  RC="$(cat "$T/rc")"; CALLS="$(cat "$T/calls")"; LOGTXT="$(cat "$T/log")"
}

run "$A $B" "$L"
eq "deletes each gate company as the exact <uuid>/ prefix" "$CALLS" "delete-prefix $A/
delete-prefix $B/"
case "$LOGTXT" in *"removed 2 company prefixes, 6 objects, 600 bytes"*) ok "one log line with prefix count and bytes" ;; *) bad "log line (got: $LOGTXT)" ;; esac

run "$A" "$L" invai_x
eq "refuses when the database is not exactly invai_gate (no delete)" "$CALLS" ""
eq "  ... and returns 1" "$RC" 1
run "$A" "$L" invai_gate2
eq "refuses a lookalike database name" "$CALLS" ""

run "$A $L" "$L"
eq "refuses a prefix that is also a company in invai; deletes the rest" "$CALLS" "delete-prefix $A/"
eq "  ... and returns 1" "$RC" 1

run "$A" ""
eq "refuses when the invai company list is empty (no delete)" "$CALLS" ""
eq "  ... and returns 1" "$RC" 1

run "manual $UP 11111111-1111-4111-8111-11111111111 $A" "$L"
eq "refuses non-UUID, upper-case and short ids" "$CALLS" "delete-prefix $A/"

# an unreadable invai_gate means no answer, never "no companies"
: >"$T/calls"
( export LOG_FILE="$T/log" GATE_DIR="$T" WORKSPACE_DIR="$T" INFRA_DIR="$T"
  source "$SRC/gate/lib.sh"; source "$SRC/gate/scratch.sh"; source "$SRC/gate/cleanup.sh"
  gate_company_ids() { return 1; }; gate_s3() { echo "$*" >>"$T/calls"; }
  gate_cleanup_files t ) 2>/dev/null
eq "unreadable invai_gate deletes nothing" "$(cat "$T/calls")" ""

# gate_valid_prefix
( source "$SRC/gate/lib.sh" 2>/dev/null; LOG_FILE=/dev/null; source "$SRC/gate/cleanup.sh"
  for p in "" "/" "manual/" "$A" "${UP}/" "$A/x/"; do gate_valid_prefix "$p" && echo "ACCEPT:$p"; done; gate_valid_prefix "$A/" && echo GOOD ) >"$T/vp" 2>/dev/null
eq "gate_valid_prefix accepts only <uuid>/" "$(cat "$T/vp")" "GOOD"

# Valkey flush: only DB 9
: >"$T/dock"
( export LOG_FILE="$T/log"; source "$SRC/gate/lib.sh"; source "$SRC/gate/cleanup.sh"
  docker() { echo "$*" >>"$T/dock"; }
  gate_full_profile_running() { return 1; }
  for d in 0 1 15 12 "" 9; do gate_flush_valkey_db "$d"; done ) 2>/dev/null
case "$(cat "$T/dock")" in *"-n 9 FLUSHDB") ok "flush runs for DB 9" ;; *) bad "flush runs for DB 9 ($(cat "$T/dock"))" ;; esac
eq "flush refuses every DB except 9 (exactly one docker call)" "$(grep -c . "$T/dock")" 1

# the compose full profile shares Valkey DB 9: the flush refuses while it runs
: >"$T/dock"
( export LOG_FILE="$T/log"; source "$SRC/gate/lib.sh"; source "$SRC/gate/cleanup.sh"
  gate_full_profile_running() { echo "local-api-1"; return 0; }
  docker() { echo "$*" >>"$T/dock"; }
  gate_flush_valkey_db 9; echo "rc=$?" >"$T/rc" ) 2>/dev/null
eq "flush of DB 9 is refused while full-profile containers run (no docker call)" "$(grep -c . "$T/dock")" 0
eq "  ... and returns 1" "$(cat "$T/rc")" "rc=1"
( export LOG_FILE="$T/log"; source "$SRC/gate/lib.sh"
  docker() { printf 'local-postgres-1\nlocal-api-1\n'; }
  gate_full_profile_running >"$T/who"; echo "rc=$?" >"$T/rc" ) 2>/dev/null
eq "gate_full_profile_running detects local-api-1" "$(cat "$T/rc")" "rc=0"
( export LOG_FILE="$T/log"; source "$SRC/gate/lib.sh"
  docker() { printf 'local-postgres-1\nlocal-valkey-1\nlocal-minio-1\n'; }
  gate_full_profile_running >"$T/who"; echo "rc=$?" >"$T/rc" ) 2>/dev/null
eq "gate_full_profile_running is quiet with only the base stack" "$(cat "$T/rc")" "rc=1"
( export LOG_FILE="$T/log"; source "$SRC/gate/lib.sh"
  docker() { return 1; }
  gate_full_profile_running >"$T/who"; echo "rc=$?" >"$T/rc" ) 2>/dev/null
eq "an unanswering docker counts as running (no answer is not all clear)" "$(cat "$T/rc")" "rc=0"

# the EXIT trap runs the cleanup only when armed, after stopping
out="$( ( export LOG_FILE="$T/log"; source "$SRC/gate/lib.sh"; source "$SRC/gate/cleanup.sh"
  gate_cleanup_run() { echo "CLEANED $1"; }; GATE_CLEANUP_ARMED=1; exit 0 ) 2>/dev/null )"
eq "the EXIT trap runs the end-of-run cleanup when armed" "$out" "CLEANED end"
out="$( ( export LOG_FILE="$T/log"; source "$SRC/gate/lib.sh"; source "$SRC/gate/cleanup.sh"
  gate_cleanup_run() { echo "CLEANED $1"; }; exit 0 ) 2>/dev/null )"
eq "the EXIT trap does nothing when not armed" "$out" ""

# s3tool refusals fire before any network call
S="$SRC/gate/s3tool.mjs"
ok "test endpoint is dead (connection refused)"
st() { node "$S" "$@" >/dev/null 2>&1; echo $?; }
for bad_prefix in "" "/" "manual/" "$A" "${UP}/" "$A/x/"; do
  eq "s3tool delete-prefix refuses '$bad_prefix'" "$(st delete-prefix "$bad_prefix")" 2
done
eq "s3tool refuses a non-local endpoint" "$(S3_ENDPOINT=https://s3.amazonaws.com st scan)" 2
eq "s3tool refuses to delete outside bucket invai-gate" "$(S3_BUCKET=invai-ci-x st delete-prefix "$A/")" 2
eq "s3tool refuses to delete in the dev bucket invai-local (T-45-5)" "$(S3_BUCKET=invai-local st delete-prefix "$A/")" 2
eq "s3tool refuses to delete in a lookalike bucket invai-gate2" "$(S3_BUCKET=invai-gate2 st delete-prefix "$A/")" 2
eq "s3tool refuses to delete in an empty-name bucket (falls back to invai-gate, dead endpoint = 1 not 0)" "$(S3_BUCKET= st delete-prefix "$A/")" 1
eq "s3tool ensure-bucket refuses invai-local" "$(S3_BUCKET=invai-local st ensure-bucket)" 2
eq "s3tool ensure-bucket refuses another name" "$(S3_BUCKET=invai-x st ensure-bucket)" 2
eq "s3tool delete-prefix with no argument is refused" "$(st delete-prefix)" 2
eq "s3tool refuses a 37-char non-uuid prefix" "$(st delete-prefix "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz/")" 2
eq "s3tool refuses a prefix with a trailing extra path" "$(st delete-prefix "$A/$A/")" 2
msg="$(node "$S" delete-prefix "" 2>&1 >/dev/null)"
case "$msg" in *refusing*) ok "empty prefix is refused by s3tool itself (message)" ;; *) bad "empty prefix refusal message ($msg)" ;; esac
msg="$(S3_BUCKET=invai-local node "$S" delete-prefix "$A/" 2>&1 >/dev/null)"
case "$msg" in *"refusing to delete in bucket 'invai-local'"*) ok "invai-local is refused with no request sent" ;; *) bad "invai-local refusal message ($msg)" ;; esac
msg="$(S3_BUCKET=invai-ci-x node "$S" delete-prefix "$A/" 2>&1 >/dev/null)"
case "$msg" in *"refusing to delete in bucket"*) ok "wrong bucket is refused before any network call" ;; *) bad "wrong bucket message ($msg)" ;; esac
msg="$(node "$S" delete-prefix "$A/" 2>&1 >/dev/null)"
case "$msg" in *ECONN*|*connect*|*refus*) ok "a valid prefix gets past the fences and fails only on the dead endpoint" ;; *) bad "valid prefix reaches the network ($msg)" ;; esac
if grep -Eq 'DeleteBucket|DeleteObjectCommand\b' "$S"; then bad "s3tool has no bucket-level or single-key delete"; else ok "s3tool has no bucket-level or single-key delete"; fi
eq "the only delete call is the validated delete-prefix" "$(grep -c 'DeleteObjectsCommand(' "$S")" 1

# gate_s3 pins the bucket for every cleanup call, whatever the caller exported
out="$( ( export LOG_FILE="$T/log"; source "$SRC/gate/lib.sh"; source "$SRC/gate/cleanup.sh"
  GATE_S3_TOOL="$T/envtool"; printf '#!/bin/sh\necho "$S3_BUCKET"\n' >"$T/envtool"; chmod +x "$T/envtool"
  S3_BUCKET=invai-local gate_s3 delete-prefix x ) 2>/dev/null )"
eq "cleanup's gate_s3 pins S3_BUCKET=invai-gate even when invai-local is exported" "$out" "invai-gate"

g_="$SRC/gate.sh"
# static: wiring in gate.sh, lib.sh and dev.sh
g="$SRC/gate.sh"; l="$SRC/gate/lib.sh"; d="$SRC/dev.sh"
grep -q 'gate_cleanup_run start' "$g" && ok "gate.sh cleans the previous run's files at the start" || bad "gate.sh start cleanup"
a="$(grep -n 'gate_cleanup_run start' "$g" | head -n1 | cut -d: -f1)"; r="$(grep -n 'pnpm db:reset' "$g" | head -n1 | cut -d: -f1)"
[ -n "$a" ] && [ -n "$r" ] && [ "$a" -lt "$r" ] && ok "start cleanup runs before db:reset" || bad "start cleanup runs before db:reset ($a vs $r)"
grep -q 'gate_full_profile_running' "$g" && ok "gate.sh refuses to start while the full profile runs" || bad "gate.sh full-profile refusal"
grep -q 'GATE_CLEANUP_ARMED=1' "$g" && ok "gate.sh arms the end-of-run cleanup" || bad "gate.sh arms the cleanup"
grep -q 'gate_cleanup_run end' "$l" && ok "lib.sh cleanup() runs the end-of-run cleanup" || bad "lib.sh end cleanup"
grep -q 'INVAI_NO_WATCH=1 pnpm dev:all' "$l" && ok "start_dev_all sets INVAI_NO_WATCH=1 (B-388)" || bad "start_dev_all sets INVAI_NO_WATCH=1 (B-388)"
nw="$(sed -n '/INVAI_NO_WATCH:-}" = 1/,/^fi$/p' "$d")"
case "$nw" in *"src/api/server.ts"*"src/worker/index.ts"*) ok "dev.sh no-watch branch starts api and worker" ;; *) bad "dev.sh no-watch branch starts api and worker" ;; esac
case "$nw" in *watch*|*--reload*) bad "dev.sh no-watch branch has no watcher" ;; *) ok "dev.sh no-watch branch has no watcher" ;; esac

exit $fail
