#!/usr/bin/env bash
# Tests for the gate's Docker clock check (T-55-4). bash 3.2 compatible. Hermetic: `docker` and
# `date` are stubs first in PATH, so no real Docker, database or file store is touched.
#
# Part 1 sources clock.sh against the stubs (bound, both directions, midpoint, unreadable, hung).
# Part 2 pins how gate.sh calls it (statements, order, golden path only).
# Part 3 runs the real gate.sh from a copy in a sandbox workspace with every tool stubbed and the
# stub Docker clock jumping off at a chosen call, so each call site is proven to end the run.
# GATE_SRC_DIR points at a copy of scripts/ to prove an undone change goes red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${GATE_SRC_DIR:-$(cd "$HERE/.." && pwd)}"
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 (found '$3')" ;; *) ok "$1" ;; esac; }

[ -f "$SRC/gate/clock.sh" ] || { bad "clock.sh exists"; exit 1; }
T="$(mktemp -d)" || { echo "FAIL - no temp dir"; exit 1; }
[ -n "$T" ] && [ -d "$T" ] || { echo "FAIL - no temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
REAL_DATE="$(command -v date)"

# date stub: `date -u +%s` pops the next value of $STUB_DATE_FILE (the last one repeats); any other
# call, and any call with no file, is the real date.
cat >"$T/bin/date" <<STUB
#!/bin/sh
if [ "\$*" = "-u +%s" ] && [ -n "\$STUB_DATE_FILE" ] && [ -s "\$STUB_DATE_FILE" ]; then
  v="\$(head -n 1 "\$STUB_DATE_FILE")"
  if [ "\$(wc -l <"\$STUB_DATE_FILE")" -gt 1 ]; then sed 1d "\$STUB_DATE_FILE" >"\$STUB_DATE_FILE.n" && mv "\$STUB_DATE_FILE.n" "\$STUB_DATE_FILE"; fi
  echo "\$v"; exit 0
fi
exec "$REAL_DATE" "\$@"
STUB
# docker stub for part 1: `docker exec <c> date -u +%s` prints STUB_C (or fails, or sleeps).
cat >"$T/bin/docker" <<STUB
#!/bin/sh
echo "\$*" >>"$T/docker.calls"
[ -z "\$STUB_SLEEP" ] || exec sleep "\$STUB_SLEEP"
[ -z "\$STUB_RC" ] || { echo "Error: No such container" >&2; exit "\$STUB_RC"; }
echo "\${STUB_C-0}"
STUB
chmod +x "$T/bin/date" "$T/bin/docker"
export PATH="$T/bin:$PATH"

# ---------- part 1: the check itself ----------

# probe <m1> <m2> <c>: sets OUT (the message) and RC of gate_clock_eval.
probe() {
  printf '%s\n%s\n' "$1" "$2" >"$T/dates"
  OUT="$(STUB_DATE_FILE="$T/dates" STUB_C="$3" LOG_FILE="$T/log" bash -c '
    source "$1/gate/lib.sh" 2>/dev/null; source "$1/gate/clock.sh"
    gate_clock_eval probe; rc=$?; echo "$GATE_CLOCK_MSG"; exit $rc' _ "$SRC" 2>&1)"
  RC=$?
}
# evalenv <env assignments...>: runs gate_clock_eval with the real date and prints "rc=N <message>".
evalenv() {
  env STUB_DATE_FILE= LOG_FILE="$T/log" "$@" bash -c '
    source "$1/gate/lib.sh" 2>/dev/null; source "$1/gate/clock.sh"
    gate_clock_eval step; echo "rc=$? $GATE_CLOCK_MSG"' _ "$SRC" 2>&1
}
M=1000000000
probe $M $M $M;            eq "equal clocks pass" "$RC" 0
probe $M $M $((M + 10));   eq "Docker 10 s ahead passes (the bound is inclusive)" "$RC" 0
probe $M $M $((M - 10));   eq "Docker 10 s behind passes" "$RC" 0
probe $M $M $((M + 11));   eq "Docker 11 s ahead fails" "$RC" 1
has "  the message names the step, the size and the side" "$OUT" "FAIL docker clock (probe): Docker is 11 s ahead of the Mac"
probe $M $M $((M - 11));   eq "Docker 11 s behind fails" "$RC" 1
has "  the message says behind" "$OUT" "Docker is 11 s behind the Mac"
probe $M $((M + 1)) $((M + 11)); eq "10.5 s of skew fails (shown as 11 s)" "$RC" 1
has "  and reads 11 s" "$OUT" "Docker is 11 s ahead"
# Slow docker exec: the Mac reads are 21 s apart; the container read in the middle is not skew.
probe 100 121 111;         eq "a 21 s exec with the container at the midpoint passes" "$RC" 0
probe 100 121 132;         eq "the same exec latency does not hide a real skew" "$RC" 1
has "  skew is measured from the midpoint (22 s)" "$OUT" "Docker is 22 s ahead"

# unreadable clocks
OUT="$(evalenv STUB_RC=1)"
has "container missing: its own message" "$OUT" "FAIL docker clock (step): could not read the Docker clock"
has "  and a failing return" "$OUT" "rc=1"
OUT="$(evalenv STUB_C=abc)"
has "non-numeric output counts as unreadable" "$OUT" "could not read the Docker clock"
OUT="$(evalenv STUB_C=)"
has "an empty answer counts as unreadable" "$OUT" "could not read the Docker clock"

# hung docker exec: bounded by GATE_CLOCK_TIMEOUT, and the hung child is killed
t0="$("$REAL_DATE" +%s)"
OUT="$(evalenv STUB_SLEEP=3187 GATE_CLOCK_TIMEOUT=1)"
t1="$("$REAL_DATE" +%s)"
has "hung docker exec: own message with the timeout" "$OUT" "FAIL docker clock (step): could not read the Docker clock within 1 s"
has "  and a failing return" "$OUT" "rc=1"
if [ $((t1 - t0)) -le 6 ]; then ok "  returned in $((t1 - t0)) s, not hung"; else bad "  took $((t1 - t0)) s"; fi
if pgrep -f "sleep 3187" >/dev/null 2>&1; then bad "  the hung child was left running"; pkill -f "sleep 3187"; else ok "  the hung child was killed"; fi

# the Postgres container comes from GATE_PG_CONTAINER
: >"$T/docker.calls"
evalenv GATE_PG_CONTAINER=custom-pg STUB_C=0 >/dev/null
has "reads the container named by GATE_PG_CONTAINER" "$(cat "$T/docker.calls")" "exec custom-pg date -u +%s"
eq "  with one docker call per check" "$(wc -l <"$T/docker.calls" | tr -d ' ')" 1

# gate_clock_check ends the run through the EXIT trap and never reaches the next statement
printf '%s\n%s\n' $M $M >"$T/dates"
OUT="$(STUB_DATE_FILE="$T/dates" STUB_C=$((M + 30)) LOG_FILE="$T/log2" bash -c '
  source "$1/gate/lib.sh" 2>/dev/null; source "$1/gate/clock.sh"
  trap "echo CLEANUP-RAN" EXIT
  gate_clock_check "after seed"
  echo NEXT-STATEMENT-RAN' _ "$SRC" 2>&1)"
RC=$?
eq "a failing check exits 1" "$RC" 1
has "  prints the FAIL line" "$OUT" "FAIL docker clock (after seed): Docker is 30 s ahead of the Mac"
has "  prints the log line" "$OUT" "log: $T/log2"
has "  the EXIT trap (cleanup) runs" "$OUT" "CLEANUP-RAN"
hasnt "  nothing after it runs" "$OUT" "NEXT-STATEMENT-RAN"
has "  the log explains in plain words" "$(cat "$T/log2")" "orb stop && orb start"
eq "  one FAIL line on stdout" "$(printf '%s\n' "$OUT" | grep -c '^FAIL ')" 1
printf '%s\n%s\n' $M $M >"$T/dates"
OUT="$(STUB_DATE_FILE="$T/dates" STUB_C=$M LOG_FILE="$T/log3" bash -c 'source "$1/gate/lib.sh" 2>/dev/null; source "$1/gate/clock.sh"; gate_clock_check fine; echo "after rc=$?"' _ "$SRC" 2>&1)"
has "a passing check prints nothing and continues" "$OUT" "after rc=0"
hasnt "  no FAIL" "$OUT" "FAIL"

# ---------- part 2: how gate.sh calls it ----------

GATE="$SRC/gate.sh"
CALLS="$(grep -n 'gate_clock_check' "$GATE" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
bad_form="$(printf '%s\n' "$CALLS" | grep -vE '^[0-9]+:[[:space:]]*gate_clock_check "[^"]+"$' || true)"
if [ -z "$CALLS" ]; then bad "gate.sh calls gate_clock_check"
elif [ -z "$bad_form" ]; then ok "every call is a bare statement (never inside \$( ), a pipe or ||)"
else bad "calls that are not bare statements: $bad_form"; fi
steps="$(printf '%s\n' "$CALLS" | sed -E 's/^[0-9]+:[[:space:]]*gate_clock_check "([^"]+)"$/\1/' | paste -sd'|' -)"
eq "call sites in order" "$steps" 'start|after $r checks|after seed|before API suite|after API suite|before browser suite|after browser suite|before floor suite|after floor suite'
first_call="$(grep -n 'gate_clock_check "start"' "$GATE" | head -n 1 | cut -d: -f1)"
scratch_line="$(grep -n '^  gate_scratch_env$' "$GATE" | head -n 1 | cut -d: -f1)"
pre_line="$(grep -n '^check_preconditions$' "$GATE" | head -n 1 | cut -d: -f1)"
if [ -n "$first_call" ] && [ -n "$scratch_line" ] && [ "$scratch_line" -lt "$first_call" ] && [ "$first_call" -lt "$pre_line" ]; then
  ok "the first check sits between gate_scratch_env and check_preconditions"
else bad "first check position (scratch $scratch_line, check ${first_call:-none}, preconditions $pre_line)"; fi
if awk '/gate_clock_check "start"/{f=1} f&&/^fi$/{print "closed"; exit}' "$GATE" | grep -q closed; then
  ok "the first check is inside the needs_golden_path block"
else bad "the first check is outside the block"; fi

# ---------- part 3: the real gate.sh in a sandbox ----------

W="$T/ws"
S="$W/stubs"
# gate.sh puts $HOME/.local/share/pnpm first on PATH; a HOME with no such folder keeps the stubs first.
mkdir -p "$T/home" "$W/invai-infra/local" "$W/invai-backend" "$W/invai-imaging" "$W/invai-floor" "$W/invai-ui" "$W/invai-web" "$S"
cp -R "$SRC" "$W/invai-infra/scripts"
for r in invai-floor invai-ui; do
  ( cd "$W/$r" && git init -q && echo x >f && git add f && git -c user.email=t@example.com -c user.name=t commit -q -m init ) >/dev/null 2>&1
done
DEV_ID=11111111-1111-4111-8111-111111111111
GATE_ID=22222222-2222-4222-8222-222222222222
cat >"$S/docker" <<STUB
#!/bin/sh
case "\$*" in
  *"date -u +%s"*)
    n=\$(( \$(cat "$T/dcount" 2>/dev/null || echo 0) + 1 )); echo \$n >"$T/dcount"
    off=0; [ "\$n" -ge "\${STUB_SKEW_FROM:-9999}" ] && off=\${STUB_SKEW:-0}
    echo \$(( \$("$REAL_DATE" -u +%s) + off )) ;;
  "inspect "*) echo healthy ;;
  "ps "*) : ;;
  *"select id from companies"*) case "\$*" in *"-d invai_gate"*) echo $GATE_ID ;; *) echo $DEV_ID ;; esac ;;
  *"select 1 from pg_database"*) case "\$*" in *"datname='invai_gate'"*) echo 1 ;; esac ;;
  *"count(*) from pg_stat_activity"*) echo 0 ;;
esac
exit 0
STUB
cat >"$S/pnpm" <<STUB
#!/bin/sh
case "\$*" in
  *dev:all*) exec sleep 3172 ;;
  *db:seed*) echo '{}' >"\$SEED_OUTPUT_FILE" ;;
  *) echo "1 passed" ;;
esac
exit 0
STUB
printf '#!/bin/sh\nexec sleep 3171\n' >"$S/uv"
printf '#!/bin/sh\nexit 0\n' >"$S/curl"
cat >"$S/s3tool" <<STUB
#!/bin/sh
case "\$1" in count) if [ "\$S3_BUCKET" = invai-local ]; then printf '0\t0\n'; else printf '3\t30\n'; fi ;; *) printf '0\t0\n' ;; esac
exit 0
STUB
chmod +x "$S"/*

# gate_run <skew from read n> [skew seconds]: sets OUT, RC; the Docker clock is right until read n.
gate_run() {
  echo 0 >"$T/dcount"; rm -rf "$W/invai-infra/.gate"
  OUT="$(cd "$W/invai-infra" && HOME="$T/home" PATH="$S:$PATH" STUB_SKEW_FROM="$1" STUB_SKEW="${2:-60}" GATE_S3_TOOL="$S/s3tool" \
    INVAI_API_PORT=43171 INVAI_IMAGING_PORT=43172 INVAI_WEB_PORT=43173 INVAI_FLOOR_PORT=43174 \
    bash scripts/gate.sh invai-floor 2>"$T/gate.err")"
  RC=$?
}
left_over() { pgrep -f "sleep 317[12]" >/dev/null 2>&1; }

gate_run 9999
eq "sandbox: a clean run passes" "$RC" 0
has "  prints the PASS lines" "$OUT" "PASS invai-floor e2e"
if [ -f "$W/invai-infra/.gate/pass.json" ]; then ok "  and writes the pass stamp"; else bad "  no pass stamp: $OUT $(tail -n 5 "$T/gate.err")"; fi
if left_over; then bad "  a stub process was left running"; pkill -f "sleep 317[12]"; else ok "  cleanup stopped what the run started"; fi
eq "  exactly 9 clock reads in a golden-path run on one repo" "$(cat "$T/dcount")" 9

n=1
for step in "start" "after invai-floor checks" "after seed" "before API suite" "after API suite" "before browser suite" "after browser suite" "before floor suite" "after floor suite"; do
  gate_run "$n" 60
  eq "sandbox: skew from read $n ends the run" "$RC" 1
  # the stub Docker clock is the real one plus 60 s, so the Mac's own second ticking may add 1
  if printf '%s\n' "$OUT" | grep -Fq "FAIL docker clock ($step): Docker is 59 s ahead of the Mac" \
    || printf '%s\n' "$OUT" | grep -Fq "FAIL docker clock ($step): Docker is 60 s ahead of the Mac" \
    || printf '%s\n' "$OUT" | grep -Fq "FAIL docker clock ($step): Docker is 61 s ahead of the Mac"; then
    ok "  the FAIL line names the step '$step'"
  else bad "  the FAIL line names the step '$step' [got: $(printf '%s' "$OUT" | head -c 300 | tr '\n' '|')]"; fi
  eq "  one clock FAIL line" "$(printf '%s\n' "$OUT" | grep -c '^FAIL docker clock')" 1
  has "  the log line follows" "$OUT" "log: "
  if [ -f "$W/invai-infra/.gate/pass.json" ]; then bad "  pass.json exists"; else ok "  no pass.json is written"; fi
  if left_over; then bad "  the EXIT trap left a stub process running"; pkill -f "sleep 317[12]"; else ok "  the EXIT trap stopped the processes the run started"; fi
  n=$((n + 1))
done

# a run that does not need the golden path never reads the Docker clock
echo 0 >"$T/dcount"; rm -rf "$W/invai-infra/.gate"
OUT="$(cd "$W/invai-infra" && HOME="$T/home" PATH="$S:$PATH" STUB_SKEW_FROM=1 STUB_SKEW=500 bash scripts/gate.sh invai-ui 2>/dev/null)"
RC=$?
eq "sandbox: an invai-ui run passes even with a skewed Docker" "$RC" 0
eq "  and never reads the Docker clock" "$(cat "$T/dcount")" 0

exit $fail
