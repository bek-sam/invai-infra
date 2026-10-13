#!/usr/bin/env bash
# Tests for scripts/purge-orphan-files.sh (T-42-2). bash 3.2 compatible.
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

# run [--apply]: env knobs INVAI_IDS, TEST_IDS, GATE_IDS, FAIL_DB; sets RC, OUT, CALLS
run() {
  : >"$T/calls"
  export T NOW OLD NEW O1 O2 LV LT LG RC1 OLD_NONUUID INVAI_IDS TEST_IDS GATE_IDS FAIL_DB
  OUT="$( ( source "$SRC"; source "$T/stubs.sh"; PURGE_NOW=$NOW; purge_main "$@"; echo "rc=$?" ) 2>&1 )"
  RC="${OUT##*rc=}"; CALLS="$(cat "$T/calls")"
}
ok "test endpoint is dead (connection refused)"
INVAI_IDS="$LV"; TEST_IDS="$LT"; GATE_IDS="$LG"; FAIL_DB=""

run
eq "dry run deletes nothing" "$CALLS" ""
case "$OUT" in *"orphan    prefixes      2  bytes            400"*) ok "dry run counts the orphan class" ;; *) bad "dry run counts orphans ($OUT)" ;; esac
case "$OUT" in *"recent    prefixes      1"*"live      prefixes      3"*) ok "dry run counts live (3 databases) and recent" ;; *) bad "live/recent counts ($OUT)" ;; esac
case "$OUT" in *"non-uuid  prefixes      1"*"root      prefixes      1"*) ok "non-UUID prefix and root objects are listed" ;; *) bad "non-uuid/root ($OUT)" ;; esac
case "$OUT" in *"invai-ci-x"*) ok "other buckets are listed" ;; *) bad "other buckets listed" ;; esac

run --apply
eq "--apply deletes exactly the two old orphans, by exact prefix" "$CALLS" "delete-prefix $O1/
delete-prefix $O2/"
case "$OUT" in *"deleted 2 prefixes, 400 bytes"*) ok "apply reports prefixes and bytes" ;; *) bad "apply report ($OUT)" ;; esac

# refusals: nothing is deleted
INVAI_IDS=""; run --apply
eq "refuses when the invai company list is empty (no delete)" "$CALLS" ""; case "$RC" in 1) ok "  ... exit 1" ;; *) bad "  ... exit 1 ($RC)" ;; esac
INVAI_IDS="$LV"; FAIL_DB=invai; run --apply
eq "refuses when invai cannot be read" "$CALLS" ""; case "$RC" in 1) ok "  ... exit 1" ;; *) bad "  ... exit 1 ($RC)" ;; esac
FAIL_DB=invai_test; run --apply
eq "refuses when another database cannot be read" "$CALLS" ""
FAIL_DB=""
# a prefix that is live only in invai_test or invai_gate stays (checked above: LT, LG not deleted)
INVAI_IDS="$LV $O1"; run --apply
eq "an id live in invai is never deleted" "$CALLS" "delete-prefix $O2/"

# F2: live-file failures are refusals, never "not live"
run_with() { # run_with <collect function body> -> overrides purge_collect_live
  : >"$T/calls"
  export T NOW OLD NEW O1 O2 LV LT LG RC1 OLD_NONUUID INVAI_IDS TEST_IDS GATE_IDS FAIL_DB
  OUT="$( ( source "$SRC"; source "$T/stubs.sh"; eval "purge_collect_live() { $1; }"; PURGE_NOW=$NOW; purge_main --apply; echo "rc=$?" ) 2>&1 )"
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

# usage
run --nope; case "$OUT" in *usage*) ok "unknown flag is refused" ;; *) bad "unknown flag ($OUT)" ;; esac
eq "unknown flag deletes nothing" "$CALLS" ""

# static
if grep -Eq 'S3_BUCKET=|DeleteBucket|mc rb|remove-bucket' "$SRC"; then bad "no bucket-level delete or bucket override in the purge script"; else ok "no bucket-level delete or bucket override in the purge script"; fi
eq "the only delete call passes <uuid>/ built from a validated prefix" "$(grep -c 'purge_s3 delete-prefix "\$p/"' "$SRC")" 1
grep -q 'purge_valid_prefix "\$p/" ||' "$SRC" && ok "last-look UUID check before the delete" || bad "last-look UUID check before the delete"
exit $fail
