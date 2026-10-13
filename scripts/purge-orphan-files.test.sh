#!/usr/bin/env bash
# Tests for scripts/purge-orphan-files.sh (T-42-2, T-46-2). bash 3.2 compatible.
# Databases and MinIO are stubbed; nothing real is read or deleted.
# PURGE_SRC points at a copy of purge-orphan-files.sh to prove a deleted fence goes red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${PURGE_SRC:-$HERE/purge-orphan-files.sh}"
fail=0
# Hermetic (T-42-2 round 2, incident 2026-10-13): every path that could reach a delete points at a
# dead endpoint and containers that do not exist, so a removed fence fails a test instead of
# deleting. The run aborts unless the endpoint is proven dead first.
export S3_ENDPOINT=http://127.0.0.1:1 S3_BUCKET=invai-local
export GATE_PG_CONTAINER=no-such-pg-container GATE_VALKEY_CONTAINER=no-such-valkey-container PURGE_PG_CONTAINER=no-such-pg-container
export DATABASE_URL=postgres://nobody:nobody@127.0.0.1:1/no_such_db MIGRATION_DATABASE_URL=postgres://nobody:nobody@127.0.0.1:1/no_such_db REDIS_URL=redis://127.0.0.1:1/9
unset GATE_S3_TOOL PURGE_S3_TOOL
if ! { out="$(node "$HERE/gate/s3tool.mjs" buckets 2>&1)"; [ $? -ne 0 ] && printf '%s' "$out" | grep -qi 'ECONNREFUSED\|connect'; }; then
  echo "ABORT - the test endpoint is not dead; refusing to run (a mutant could delete real files)"; exit 3
fi
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
NOW=1800000000; OLD=$((NOW - 7 * 3600)); NEW=$((NOW - 3600))
O1=aaaaaaaa-0000-4000-8000-000000000001   # old orphan
O2=aaaaaaaa-0000-4000-8000-000000000002   # old orphan
LV=bbbbbbbb-0000-4000-8000-000000000001   # live in invai
LT=bbbbbbbb-0000-4000-8000-000000000002   # live only in invai_test
LG=bbbbbbbb-0000-4000-8000-000000000003   # live only in invai_gate
RC1=cccccccc-0000-4000-8000-000000000001  # recent
OLD_NONUUID="manual"

cat >"$T/stubs.sh" <<'STUBS'
purge_databases() { printf '%s\n' postgres_x invai invai_test invai_gate invai_tpl; }
purge_company_ids() {
  if [ "${FAIL_DB:-}" = "$1" ]; then return 1; fi
  case "$1" in
    invai) printf '%s\n' $INVAI_IDS ;;
    invai_test) printf '%s\n' $TEST_IDS ;;
    invai_gate) printf '%s\n' $GATE_IDS ;;
  esac
  return 0
}
STUBS
cat >"$T/stubs_s3.sh" <<'STUBS'
purge_s3() {
  case "$1" in
    scan)
      printf '%s\t2\t200\t%s\n' "$O1" $OLD "$O2" $OLD "$LV" $OLD "$LT" $OLD "$LG" $OLD "$RC1" $NEW "$OLD_NONUUID" $OLD
      printf '(root)\t1\t5\t%s\n' $OLD ;;
    buckets) printf 'invai-local\ninvai-ci-x\n' ;;
    *) echo "$*" >>"$T/calls" ;;
  esac
}
STUBS

# run <args>: env knobs INVAI_IDS, TEST_IDS, GATE_IDS, FAIL_DB; sets RC, OUT, CALLS
run() {
  : >"$T/calls"
  export T NOW OLD NEW O1 O2 LV LT LG RC1 OLD_NONUUID INVAI_IDS TEST_IDS GATE_IDS FAIL_DB
  OUT="$( ( source "$SRC"; source "$T/stubs.sh"; source "$T/stubs_s3.sh"; PURGE_NOW=$NOW; purge_main "$@"; echo "rc=$?" ) 2>&1 )"
  RC="${OUT##*rc=}"; CALLS="$(cat "$T/calls")"
}
ok "test endpoint is dead (connection refused)"
INVAI_IDS="$LV"; TEST_IDS="$LT"; GATE_IDS="$LG"; FAIL_DB=""

run --bucket invai-gate
eq "dry run deletes nothing" "$CALLS" ""
case "$OUT" in *"orphan    prefixes      2  bytes            400  (bucket invai-gate)"*) ok "dry run counts the orphan class" ;; *) bad "dry run counts orphans ($OUT)" ;; esac
case "$OUT" in *"recent    prefixes      1"*"live      prefixes      3"*) ok "dry run counts live (3 databases) and recent" ;; *) bad "live/recent counts ($OUT)" ;; esac
case "$OUT" in *"non-uuid  prefixes      1"*"root      prefixes      1"*) ok "non-UUID prefix and root objects are listed" ;; *) bad "non-uuid/root ($OUT)" ;; esac
case "$OUT" in *"invai-ci-x"*) ok "other buckets are listed" ;; *) bad "other buckets listed" ;; esac

run --bucket invai-gate --apply
eq "--apply deletes exactly the two old orphans, by exact prefix" "$CALLS" "delete-prefix $O1/
delete-prefix $O2/"
case "$OUT" in *"deleted 2 prefixes, 400 bytes"*) ok "apply reports prefixes and bytes" ;; *) bad "apply report ($OUT)" ;; esac

# refusals: nothing is deleted
INVAI_IDS=""; run --bucket invai-gate --apply
eq "refuses when the invai company list is empty (no delete)" "$CALLS" ""; case "$RC" in 1) ok "  ... exit 1" ;; *) bad "  ... exit 1 ($RC)" ;; esac
INVAI_IDS="$LV"; FAIL_DB=invai; run --bucket invai-gate --apply
eq "refuses when invai cannot be read" "$CALLS" ""; case "$RC" in 1) ok "  ... exit 1" ;; *) bad "  ... exit 1 ($RC)" ;; esac
FAIL_DB=invai_test; run --bucket invai-gate --apply
eq "refuses when another database cannot be read" "$CALLS" ""
FAIL_DB=""
# a prefix that is live only in invai_test or invai_gate stays (checked above: LT, LG not deleted)
INVAI_IDS="$LV $O1"; run --bucket invai-gate --apply
eq "an id live in invai is never deleted" "$CALLS" "delete-prefix $O2/"

# F2: live-file failures are refusals, never "not live"
run_with() { # run_with <collect function body> -> overrides purge_collect_live
  : >"$T/calls"
  export T NOW OLD NEW O1 O2 LV LT LG RC1 OLD_NONUUID INVAI_IDS TEST_IDS GATE_IDS FAIL_DB
  OUT="$( ( source "$SRC"; source "$T/stubs.sh"; source "$T/stubs_s3.sh"; eval "purge_collect_live() { $1; }"; PURGE_NOW=$NOW; purge_main --bucket invai-gate --apply; echo "rc=$?" ) 2>&1 )"
  RC="${OUT##*rc=}"; CALLS="$(cat "$T/calls")"
}
run_with ': >"$1"; echo "$LV" >"$1.invai"; return 0'
eq "an empty live file refuses (nothing deleted)" "$CALLS" ""; eq "  ... exit 1" "$RC" 1
run_with 'rm -f "$1" "$1.invai"; return 0'
eq "a missing live file refuses (nothing deleted)" "$CALLS" ""; eq "  ... exit 1" "$RC" 1
run_with 'echo "$LT" >"$1"; echo "$LV" >"$1.invai"; return 0'
eq "a live file lacking the invai ids just read refuses" "$CALLS" ""; eq "  ... exit 1" "$RC" 1
run_with 'echo "$LV" >"$1"; echo "$LV" >"$1.invai"; chmod 000 "$1"; return 0'
eq "an unreadable live file (grep exit 2) refuses, never 'not live'" "$CALLS" ""; eq "  ... exit 1" "$RC" 1
( source "$SRC"; printf '%s\t1\t1\t1\n' "$O1" | purge_plan "$T/no-such-file" 1800000000 >"$T/o" 2>/dev/null; echo "rc=$?" >"$T/rc" )
eq "purge_plan: an old uuid prefix with an unreadable live file is not an orphan" "$(cat "$T/o")|$(cat "$T/rc")" "|rc=1"
grep -q 'purge_check_live "\$live"' "$SRC" && ok "main checks the live file before planning" || bad "main checks the live file"


# ---- T-46-2: the purge names and fences its bucket (S-84). The real purge_s3 wrapper runs against a tool stub. ----
cat >"$T/tool.sh" <<'TOOL'
#!/bin/sh
echo "S3_BUCKET=$S3_BUCKET $*" >>"$TOOLLOG"
case "$1" in
  scan) printf '%s\t2\t200\t%s\n' "$O1" "$OLD" "$O2" "$OLD" "$LV" "$OLD" ;;
  buckets) printf 'invai-local\ninvai-gate\ninvai-ci-x\n' ;;
  delete-prefix) printf '2\t200\n' ;;
esac
TOOL
chmod +x "$T/tool.sh"
run_tool() { # run_tool <purge args> -> RC, OUT, TOOLCALLS (every call the purge made to the s3 helper)
  : >"$T/toolcalls"
  export T NOW OLD NEW O1 O2 LV LT LG RC1 OLD_NONUUID INVAI_IDS TEST_IDS GATE_IDS FAIL_DB
  OUT="$( ( export TOOLLOG="$T/toolcalls" PURGE_S3_TOOL="$T/tool.sh"; source "$SRC"; source "$T/stubs.sh"; PURGE_NOW=$NOW; purge_main "$@"; echo "rc=$?" ) 2>&1 )"
  RC="${OUT##*rc=}"; TOOLCALLS="$(cat "$T/toolcalls")"
}
INVAI_IDS="$LV"; TEST_IDS="$LT"; GATE_IDS="$LG"; FAIL_DB=""

run_tool
eq "no --bucket: refused, exit 2" "$RC" 2
eq "no --bucket: not one request reaches the s3 helper" "$TOOLCALLS" ""
case "$OUT" in *"--bucket <name> is required"*) ok "no --bucket: the refusal says why" ;; *) bad "no --bucket message ($OUT)" ;; esac
run_tool --apply
eq "--apply without --bucket: refused, exit 2, no request" "$RC|$TOOLCALLS" "2|"
run_tool --bucket
eq "--bucket without a value: refused, no request" "$RC|$TOOLCALLS" "2|"
run_tool --bucket invai-gate --bucket invai-local
eq "--bucket twice: refused, no request" "$RC|$TOOLCALLS" "2|"
run_tool --bucket 'INVAI local'
eq "a bad bucket name: refused, no request" "$RC|$TOOLCALLS" "2|"

run_tool --bucket invai-local
eq "dry run on invai-local succeeds" "$RC" 0
case "$TOOLCALLS" in *delete-prefix*) bad "dry run on invai-local sent a delete ($TOOLCALLS)" ;; *) ok "dry run on invai-local sends no delete" ;; esac
n_all="$(printf '%s\n' "$TOOLCALLS" | grep -c .)"; n_b="$(printf '%s\n' "$TOOLCALLS" | grep -c '^S3_BUCKET=invai-local ')"
eq "dry run: every s3 call carried S3_BUCKET=invai-local although the environment says invai-local too" "$n_all" "$n_b"
bad_lines="$(printf '%s\n' "$OUT" | grep -v '^rc=' | grep -v '^  ' | grep -vc 'invai-local')"
eq "dry run: every output line names the scanned bucket" "$bad_lines" 0

run_tool --bucket invai-local --apply
eq "--apply in invai-local: refused (exit 1)" "$RC" 1
eq "--apply in invai-local: zero requests reach the s3 helper" "$TOOLCALLS" ""
case "$OUT" in *"OI-53"*) ok "--apply in invai-local: the refusal says how to ask (OI-53)" ;; *) bad "OI-53 hint ($OUT)" ;; esac
eq "--apply refusal is one line" "$(printf '%s\n' "$OUT" | grep -v '^rc=' | grep -c .)" 1
run_tool --bucket invai-ci-x --apply
eq "--apply in any other bucket: refused, zero requests" "$RC|$TOOLCALLS" "1|"

# S3_BUCKET in the environment (the test file exports invai-local) can not move the purge's bucket
run_tool --bucket invai-gate --apply
eq "--apply in invai-gate succeeds" "$RC" 0
eq "invai-gate: the two orphans are deleted by exact prefix" "$(printf '%s\n' "$TOOLCALLS" | grep -c 'delete-prefix')" 2
eq "invai-gate: every call (scan, buckets, deletes) carried S3_BUCKET=invai-gate over an exported invai-local" \
  "$(printf '%s\n' "$TOOLCALLS" | grep -c '^S3_BUCKET=invai-gate ')" "$(printf '%s\n' "$TOOLCALLS" | grep -c .)"
case "$OUT" in *"bucket invai-gate"*"deleted 2 prefixes, 400 bytes from bucket invai-gate"*) ok "output names invai-gate" ;; *) bad "output names invai-gate ($OUT)" ;; esac
case "$OUT" in *"bucket invai-local"*) bad "output of an invai-gate run says invai-local ($OUT)" ;; *) ok "output of an invai-gate run never says invai-local" ;; esac
if printf '%s\n' "$OUT" | grep -qE '^  invai-gate$'; then bad "the scanned bucket is not listed as 'other'"; else ok "the scanned bucket is not listed as 'other'"; fi

# the default (node) branch of the wrapper: a fake s3tool.mjs in PURGE_TOOLS_DIR records the S3_BUCKET it was started with
mkdir -p "$T/fakegate"
cat >"$T/fakegate/s3tool.mjs" <<'FAKE'
import { appendFileSync } from "node:fs";
appendFileSync(process.env.TOOLLOG, `S3_BUCKET=${process.env.S3_BUCKET} ${process.argv.slice(2).join(" ")}\n`);
if (process.argv[2] === "scan") process.stdout.write("(root)\t1\t1\t1\n");
FAKE
: >"$T/toolcalls"
OUT="$( ( unset PURGE_S3_TOOL; export TOOLLOG="$T/toolcalls" PURGE_TOOLS_DIR="$T/fakegate" INVAI_IDS="$LV" TEST_IDS="" GATE_IDS="" FAIL_DB="" NOW; source "$SRC"; source "$T/stubs.sh"; PURGE_NOW=$NOW; purge_main --bucket invai-gate; echo "rc=$?" ) 2>&1 )"
eq "node branch: scan and buckets carried S3_BUCKET=invai-gate over an exported invai-local" "$(sort -u "$T/toolcalls" | tr '\n' ';')" "S3_BUCKET=invai-gate buckets;S3_BUCKET=invai-gate scan;"

# usage
run --bucket invai-gate --nope; case "$OUT" in *usage*) ok "unknown flag is refused" ;; *) bad "unknown flag ($OUT)" ;; esac
eq "unknown flag deletes nothing" "$CALLS" ""

# static
if grep -Eq 'DeleteBucket|mc rb|remove-bucket' "$SRC"; then bad "no bucket-level delete in the purge script"; else ok "no bucket-level delete in the purge script"; fi
eq "S3_BUCKET is set only from PURGE_BUCKET, on both s3tool call forms" "$(grep -o 'S3_BUCKET="\$PURGE_BUCKET"' "$SRC" | wc -l | tr -d ' ')" 2
eq "no other S3_BUCKET assignment in the purge script" "$(grep -v '^#' "$SRC" | grep -o 'S3_BUCKET=' | wc -l | tr -d ' ')" 2
eq "the only delete call passes <uuid>/ built from a validated prefix" "$(grep -c 'purge_s3 delete-prefix "\$p/"' "$SRC")" 1
grep -q 'purge_valid_prefix "\$p/" ||' "$SRC" && ok "last-look UUID check before the delete" || bad "last-look UUID check before the delete"
eq "the apply allow-list is exactly invai-gate" "$(grep -c '^PURGE_APPLY_BUCKETS="invai-gate"$' "$SRC")" 1
exit $fail
