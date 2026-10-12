#!/usr/bin/env bash
# Tests for reset_rate_buckets / gate_reset_buckets_for (T-36-5, B-350). bash 3.2 compatible.
# Uses scratch Valkey DB 12 in the local container and removes only the keys it made.
# GATE_SRC_DIR (default: this repo's scripts/) points at an older checkout to prove red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${GATE_SRC_DIR:-$(cd "$HERE/.." && pwd)}"
C="${GATE_VALKEY_CONTAINER:-local-valkey-1}"
DB=12
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
vc() { docker exec "$C" valkey-cli -n "$DB" "$@"; }
cleanup() { for k in tb:x tb:reads:co1 tb:auth:co1 rl:x bull:x revoked:x; do vc DEL "$k" >/dev/null 2>&1; done; }
trap cleanup EXIT

if ! grep -q 'reset_rate_buckets' "$SRC/gate/lib.sh" 2>/dev/null; then
  bad "lib.sh defines reset_rate_buckets"; exit 1
fi
if ! docker exec "$C" valkey-cli ping >/dev/null 2>&1; then bad "container $C reachable"; exit 1; fi
if [ "$(vc DBSIZE | tr -d '\r')" != "0" ]; then bad "scratch DB $DB is empty before the test (refusing to use it)"; exit 1; fi

run() { # run <url> -> prints function output; sets nothing else
  ( export LOG_FILE=/dev/null GATE_REDIS_URL="$1"; source "$SRC/gate/lib.sh"; reset_rate_buckets; echo "rc=$?" )
}

vc SET tb:x 1 >/dev/null; vc SET tb:reads:co1 1 >/dev/null; vc SET tb:auth:co1 1 >/dev/null
vc SET rl:x 1 >/dev/null; vc SET bull:x 1 >/dev/null; vc SET revoked:x 1 >/dev/null

out="$(run redis://localhost:6379/$DB)"
case "$out" in *"deleted 3"*) ok "logs the count (deleted 3)" ;; *) bad "logs the count (got: $out)" ;; esac
case "$out" in *"rc=0"*) ok "returns 0" ;; *) bad "returns 0 (got: $out)" ;; esac
eq "tb:* keys gone" "$(vc EXISTS tb:x tb:reads:co1 tb:auth:co1 | tr -d '\r')" "0"
eq "rl:x, bull:x, revoked:x stay" "$(vc EXISTS rl:x bull:x revoked:x | tr -d '\r')" "3"
out="$(run redis://localhost:6379/$DB)"
case "$out" in *"deleted 0"*) ok "second run deletes 0" ;; *) bad "second run deletes 0 (got: $out)" ;; esac

for u in redis://redis.example.com:6379/0 redis://10.0.0.5:6379/0 redis://localhost:6379/15 http://localhost:6379/0; do
  out="$(run "$u")"
  case "$out" in *"refused"*"rc=1"*) ok "refuses $u" ;; *) bad "refuses $u (got: $out)" ;; esac
done
eq "refused runs left rl:x alone" "$(vc EXISTS rl:x | tr -d '\r')" "1"

# gate step: a refusal fails the step with a message
out="$( export LOG_FILE=/dev/null GATE_REDIS_URL=redis://example.com:6379/0; source "$SRC/gate/lib.sh"; gate_reset_buckets_for "x suite"; echo "failed=$GATE_OVERALL_FAILED" )"
case "$out" in *"FAIL golden-path rate-limit reset"*"failed=1"*) ok "gate step fails on refusal" ;; *) bad "gate step fails on refusal (got: $out)" ;; esac

# static: gate.sh resets before each of the three suites and the dev DB flush never appears
n=$(grep -c 'gate_reset_buckets_for' "$SRC/gate.sh")
eq "gate.sh calls the reset 3 times" "$n" "3"
if grep -vE '^[[:space:]]*#' "$SRC/gate/lib.sh" "$SRC/gate.sh" | grep -qiE 'flushdb|flushall|KEYS '; then bad "no FLUSH*/KEYS in gate code"; else ok "no FLUSH*/KEYS in gate code"; fi

exit $fail
