#!/usr/bin/env bash
# Tests for the gate's own backend test database, Valkey handling and detection (T-46-1, B-426).
# bash 3.2 compatible. Hermetic: psql, docker and pnpm are stubbed (a stub `docker` first in PATH),
# so no database, Valkey or MinIO is touched. The last section is live and creates, uses and drops
# only a database it names itself (invai_test_gate_<stamp>_<pid>); it is skipped when the local
# Postgres does not answer within a few seconds. GATE_SRC_DIR points at a copy of scripts/ to prove
# an undone fix goes red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${GATE_SRC_DIR:-$(cd "$HERE/.." && pwd)}"
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 (found '$3')" ;; *) ok "$1" ;; esac; }

[ -f "$SRC/gate/testdb.sh" ] || { bad "testdb.sh exists"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ws/invai-backend" "$T/ws/invai-infra/.gate" "$T/bin"

cat >"$T/bin/pnpm" <<EOF
#!/bin/sh
echo \$\$ >"$T/pnpmpid"
{ echo "TEST_DATABASE_URL=\$TEST_DATABASE_URL"; echo "TEST_MIGRATION_DATABASE_URL=\$TEST_MIGRATION_DATABASE_URL"
  echo "REDIS_URL=\$REDIS_URL"; echo "TEST_REDIS_URL=\${TEST_REDIS_URL-<unset>}"; echo "PGAPPNAME=\$PGAPPNAME"; } >"$T/capt"
sleep 1
exit \${STUB_RC:-0}
EOF
cat >"$T/bin/docker" <<EOF
#!/bin/sh
case "\$*" in
  *--scan*) echo test-redis-db-lock:7 ;;
  *GET*) echo "\$(cat "$T/pnpmpid" 2>/dev/null):0000" ;;
esac
exit 0
EOF
chmod +x "$T/bin/pnpm" "$T/bin/docker"

# in_env <snippet>: runs it with lib, scratch, cleanup and testdb sourced against the temp workspace.
in_env() {
  ( export LOG_FILE="$T/log" WORKSPACE_DIR="$T/ws" INFRA_DIR="$T/ws/invai-infra" GATE_DIR="$T/ws/invai-infra/.gate" API_PORT=3000
    source "$SRC/gate/lib.sh"; source "$SRC/gate/scratch.sh"; source "$SRC/gate/cleanup.sh"; source "$SRC/gate/testdb.sh"
    eval "$1" )
}

# ---------- names ----------
N="$(in_env 'gate_test_db_name')"
case "$N" in invai_test_gate_*) ok "the name is invai_test_gate_<run id>: $N" ;; *) bad "name shape ($N)" ;; esac
printf '%s' "$N" | grep -Eq '^invai_test_gate_[0-9]{14}_[0-9]+$' && ok "name is [a-z0-9_] only, stamp plus pid" || bad "name charset"
printf '%s' "$N" | grep -Eq '(^|_)test(_|$)' && ok "db-safety.ts accepts it (whole 'test' segment)" || bad "db-safety segment"
printf '%s' "$N" | grep -Eq '^invai_test_[0-9]+$' && bad "must not match the harness stale-drop regex" || ok "never matches the harness stale-drop regex ^invai_test_[0-9]+\$"
[ "$N" != invai_test ] && ok "is not the shared invai_test" || bad "shared invai_test"
N2="$(bash -c 'source "$1/gate/lib.sh"; source "$1/gate/testdb.sh"; gate_test_db_name' _ "$SRC" 2>/dev/null)"
N="$(bash -c 'source "$1/gate/lib.sh"; source "$1/gate/testdb.sh"; gate_test_db_name' _ "$SRC" 2>/dev/null)"
[ "$N" != "$N2" ] && ok "two gate runs get different names" || bad "two runs got the same name ($N)"
eq "one run agrees with itself" "$(in_env 'a="$(gate_test_db_name)"; sleep 1; b="$(gate_test_db_name)"; [ "$a" = "$b" ] && echo same')" same
for v in invai_test invai_test_tpl invai_test_12345 invai_gate invai "invai_test_gate_x" "invai_test_gate_20261013112800_1;drop" ""; do
  in_env "gate_test_db_valid '$v'" && bad "valid() refuses '$v'" || ok "valid() refuses '$v'"
done
in_env "gate_test_db_valid invai_test_gate_20261013112800_4242" && ok "valid() accepts a gate name" || bad "valid() accepts a gate name"

# ---------- run_suite end to end with stubs ----------
# bash 3.2 cannot parse a case pattern's ")" inside $( ), so the psql stub lives in a sourced file.
cat >"$T/stub.sh" <<'STUB'
gate_psql_admin() {
  echo "$1" >>"$T/stmts"
  case "$1" in
    *"from pg_stat_activity where datname="*backend_type*) if [ "$FOREIGN" = 1 ]; then echo 'other-proc|172.17.0.1|active'; fi ;;
  esac
  return 0
}
STUB
# rs <pnpm exit code> <foreign session 0|1> -> OUT (gate stdout+state), ERR, LOGTXT, STMTS, CAPT
rs() {
  : >"$T/log"; : >"$T/stmts"; rm -f "$T/capt" "$T/pnpmpid" "$T/err"
  OUT="$(
    export LOG_FILE="$T/log" WORKSPACE_DIR="$T/ws" INFRA_DIR="$T/ws/invai-infra" GATE_DIR="$T/ws/invai-infra/.gate" API_PORT=3000
    export PATH="$T/bin:$PATH" STUB_RC="$1" GATE_WATCH_INTERVAL=0.2 TMPDIR="$T"
    # the hostile environment the golden path exports and a developer shell may carry
    export REDIS_URL=redis://localhost:6379/9 TEST_REDIS_URL=redis://localhost:6379/15
    export DATABASE_URL=postgres://invai_app:invai@localhost:5432/invai_gate
    source "$SRC/gate/lib.sh"; source "$SRC/gate/scratch.sh"; source "$SRC/gate/cleanup.sh"; source "$SRC/gate/testdb.sh"
    FOREIGN="$2"
    source "$T/stub.sh"
    run_suite invai-backend test 2>"$T/err"
    echo "overall_failed=$GATE_OVERALL_FAILED"
  )"
  ERR="$(cat "$T/err" 2>/dev/null)"; LOGTXT="$(cat "$T/log")"; STMTS="$(cat "$T/stmts")"; CAPT="$(cat "$T/capt" 2>/dev/null)"
}

rs 0 0
has "suite sees TEST_DATABASE_URL on a gate database" "$CAPT" "TEST_DATABASE_URL=postgres://invai_app:invai@localhost:5432/invai_test_gate_"
has "suite sees TEST_MIGRATION_DATABASE_URL on the same gate database" "$CAPT" "TEST_MIGRATION_DATABASE_URL=postgres://invai:invai@localhost:5432/invai_test_gate_"
hasnt "suite env no longer names invai_test" "$(printf '%s' "$CAPT" | grep -E 'DATABASE_URL=.*/invai_test$')" "invai_test"
hasnt "suite env names no Valkey DB 15" "$CAPT" "/15"
hasnt "suite env names no Valkey DB 9 (the gate stack's)" "$CAPT" "/9"
has "REDIS_URL is reset to the DB 0 base URL, so the harness claims a DB" "$CAPT" "REDIS_URL=redis://localhost:6379
"
has "no TEST_REDIS_URL reaches the suite (the ambient one is removed)" "$CAPT" "TEST_REDIS_URL=<unset>"
has "PGAPPNAME marks the suite's connections" "$CAPT" "PGAPPNAME=invai-gate-"
db="$(printf '%s' "$CAPT" | sed -n 's/^TEST_DATABASE_URL=.*\///p')"
case "$db" in invai_test_gate_*) ok "database under test: $db" ;; *) bad "database under test ($db)" ;; esac
has "the gate created that database" "$STMTS" "create database $db owner invai"
has "the gate granted the app role connect" "$STMTS" "grant connect on database $db to invai_app"
has "the gate dropped that database after a passing suite" "$STMTS" "drop database if exists $db"
has "the log names the database" "$LOGTXT" "gate backend suite: database $db"
has "the log names the Valkey DB the harness claimed (read back from the registry)" "$LOGTXT" "Valkey DB: 7 (claimed by the test harness"
has "no foreign session: the log says so" "$LOGTXT" "no other application connected to $db"
eq "a clean suite leaves the gate green" "$(printf '%s' "$OUT" | grep -c 'overall_failed=0')" 1

rs 1 0
has "the gate dropped the database after a FAILING suite too" "$STMTS" "drop database if exists"
has "a failing suite is reported" "$OUT" "FAIL invai-backend test:"

# ---------- detection ----------
rs 1 1
has "a foreign session is reported in the log" "$LOGTXT" "GATE DETECTION: another application was connected to"
has "...with its application name" "$LOGTXT" "other-proc|172.17.0.1|active"
has "the FAIL line carries the hint next to the failure" "$OUT" "another application connected to"
rs 0 1
has "a passing suite with a foreign session still logs it" "$LOGTXT" "GATE DETECTION"
has "...and warns on stderr (stdout stays PASS/FAIL only)" "$ERR" "WARN invai-backend test passed, but another application"
hasnt "...without a hint in the PASS line" "$OUT" "another application connected"

# ---------- cleanup on a killed run ----------
: >"$T/stmts"
in_env 'gate_psql_admin() { echo "$1" >>"$T/stmts"; return 0; }; GATE_TEST_DB_CREATED=1; cleanup' >/dev/null 2>&1
has "the EXIT trap drops the gate test database a killed run created" "$(cat "$T/stmts")" "drop database if exists invai_test_gate_"
: >"$T/stmts"
in_env 'gate_psql_admin() { echo "$1" >>"$T/stmts"; return 0; }; cleanup' >/dev/null 2>&1
hasnt "...and drops nothing when none was created" "$(cat "$T/stmts")" "drop database"

# ---------- refusals: never create or drop another name ----------
: >"$T/stmts"
in_env 'gate_psql_admin() { echo "$1" >>"$T/stmts"; return 0; }; for n in invai_test invai_test_tpl invai_test_999 invai_gate invai; do gate_test_db_drop $n; gate_test_db_create $n; done' >/dev/null 2>&1
eq "create and drop refuse invai_test, invai_test_tpl, invai_test_<pid>, invai_gate and invai" "$(cat "$T/stmts")" ""

# ---------- preconditions ----------
pc() { # <sessions> <exists>
  in_env "gate_psql_admin() { echo \"\$1\" >>'$T/stmts'; case \"\$1\" in *'count(*)'*) echo $1 ;; *'select 1 from pg_database'*) [ $2 = 1 ] && echo 1 ;; esac; return 0; }
          docker() { echo \"docker \$*\" >>'$T/stmts'; return 0; }
          ( check_preconditions ) 2>&1; echo rc=\$?"
}
: >"$T/stmts"
case "$(pc 0 0)" in *rc=0) ok "preconditions pass when the gate's database name is free" ;; *) bad "preconditions pass when free" ;; esac
case "$(pc 3 0)" in *"open connection(s) from a process this gate did not start"*rc=1) ok "preconditions refuse a stray holder of the gate's database" ;; *) bad "preconditions refuse a holder" ;; esac
case "$(pc 0 1)" in *"already exists"*rc=1) ok "preconditions refuse a name that already exists" ;; *) bad "preconditions refuse an existing name" ;; esac
hasnt "preconditions no longer look at invai_test" "$(cat "$T/stmts")" "invai_test'"
hasnt "preconditions no longer count Valkey DB 15 clients" "$(cat "$T/stmts")" "client list"

# ---------- leftovers at start ----------
now_stamp="$(date -u +%Y%m%d%H%M%S)"
: >"$T/stmts"
in_env "gate_psql_admin() { echo \"\$1\" >>'$T/stmts'; case \"\$1\" in *'from pg_database d'*)
  printf '%s\n' 'invai_test_gate_20200101000000_11|0' 'invai_test_gate_20200101000000_12|2' 'invai_test_gate_${now_stamp}_13|0' 'invai_test_tpl|0' 'invai_test_123|0' 'invai|0' ;; esac; return 0; }
  gate_test_db_drop_leftovers" >/dev/null 2>&1
S="$(cat "$T/stmts")"
has "a leftover old idle gate database is dropped" "$S" "drop database if exists invai_test_gate_20200101000000_11"
hasnt "a leftover with open sessions is left alone" "$S" "drop database if exists invai_test_gate_20200101000000_12"
hasnt "a young gate database (maybe a live concurrent gate) is left alone" "$S" "_${now_stamp}_13"
hasnt "invai_test_tpl is never dropped" "$S" "drop database if exists invai_test_tpl"
hasnt "invai_test_<pid> is never dropped" "$S" "drop database if exists invai_test_123"
eq "the dev database is never dropped" "$(printf '%s\n' "$S" | grep -cx 'drop database if exists invai')" 0

# ---------- helpers ----------
eq "descendants of a root from 'pid ppid' lines" "$(printf '5 1\n6 5\n7 6\n8 1\n' | in_env 'gate_descendants_from 5' | tr '\n' ' ')" "5 6 7 "
eq "claim lookup returns the DB whose pid is ours" "$(printf 'test-redis-db-lock:3 99:aa\ntest-redis-db-lock:5 7:bb\n' | in_env 'gate_claim_db_for_pids "6 7"')" 5
in_env 'printf "test-redis-db-lock:3 99:aa\n" | gate_claim_db_for_pids "6 7"' >/dev/null && bad "no claim of ours -> no answer" || ok "no claim of ours -> no answer"

# ---------- live: a database this test creates and drops itself ----------
probe() { ( docker exec local-postgres-1 true >/dev/null 2>&1 & p=$!; i=0; while kill -0 $p 2>/dev/null && [ $i -lt 8 ]; do sleep 1; i=$((i+1)); done; if kill -0 $p 2>/dev/null; then kill $p 2>/dev/null; exit 1; fi; wait $p ) ; }
if probe; then
  cat >"$T/live.sh" <<'LIVE'
source "$SRC/gate/lib.sh"; source "$SRC/gate/scratch.sh"; source "$SRC/gate/cleanup.sh"; source "$SRC/gate/testdb.sh"
GATE_WATCH_INTERVAL=0.3
db="$(gate_test_db_name)"; app="$(gate_app_name)"
gate_test_db_create "$db" || { echo "live: create failed"; exit 0; }
echo "exists=$(gate_psql_admin "select count(*) from pg_database where datname='$db'")"
docker exec -e PGAPPNAME=other-live local-postgres-1 psql -U invai -d "$db" -Atc "select pg_sleep(4)" >/dev/null 2>&1 & fp=$!
docker exec -e PGAPPNAME="$app" local-postgres-1 psql -U invai -d "$db" -Atc "select pg_sleep(4)" >/dev/null 2>&1 & mp=$!
gate_watch_start "$db" "$app" "$$"; sleep 3; gate_watch_stop
gate_watch_report "$db"; echo "report_rc=$?"
wait $fp $mp 2>/dev/null
gate_test_db_drop "$db"
echo "after_drop=$(gate_psql_admin "select count(*) from pg_database where datname='$db'")"
echo "db=$db"
LIVE
  L="$(LOG_FILE="$T/log" WORKSPACE_DIR="$T/ws" INFRA_DIR="$T/ws/invai-infra" GATE_DIR="$T/ws/invai-infra/.gate" API_PORT=3000 TMPDIR="$T" SRC="$SRC" bash "$T/live.sh" 2>&1)"
  has "live: the gate created its database" "$L" "exists=1"
  has "live: another application on the gate's database is detected (report returns 1)" "$L" "report_rc=1"
  has "live: it names the application" "$(cat "$T/log")" "other-live"
  hasnt "live: the gate's own marker is not reported" "$(cat "$T/log")" "invai-gate-"
  has "live: the database is gone after the drop" "$L" "after_drop=0"
  ldb="$(printf '%s\n' "$L" | sed -n 's/^db=//p')"
  if [ -n "$ldb" ] && [ "$(docker exec local-postgres-1 psql -U invai -d postgres -Atc "select count(*) from pg_database where datname='$ldb'" 2>/dev/null)" = 0 ]; then ok "live: independent check, $ldb does not exist"; else bad "live: $ldb still exists"; fi
else
  echo "SKIP - live section: local Postgres did not answer"
fi
exit $fail
