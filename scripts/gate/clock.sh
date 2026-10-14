#!/usr/bin/env bash
# Docker clock check (T-55-4, wave 54 lesson). Sourced by gate.sh after lib.sh; bash 3.2 compatible.
#
# Wave 54's gate ran with the OrbStack VM clock about 11 minutes off the Mac, and every
# time-based assertion (rate limits, token expiry, "created in the last N minutes") went red for
# no product reason. The gate now compares the two clocks before it starts and between suites,
# and stops at once when they differ.
#
# - Only the Postgres container is read ($GATE_PG_CONTAINER): every container shares the one
#   OrbStack VM kernel clock, so MinIO would add nothing.
# - Skew uses the midpoint of two Mac reads around the container read, |2c - m1 - m2| compared
#   with 2 * bound, so the latency of `docker exec` does not count as skew. Bound: 10 s (pass at
#   10, fail at 11).
# - The container read runs in the background and is polled every 0.2 s up to GATE_CLOCK_TIMEOUT
#   (default 15 s), then killed: macOS has no `timeout`, and a hung Docker must not hang the gate.
# - gate_clock_check is called as its own statement, never inside $( ... ): on a failure it
#   prints one FAIL line plus the log line and `exit 1`s, so the EXIT trap (cleanup) runs and
#   write_stamp is never reached. Inside a subshell the exit would only leave the subshell.

GATE_PG_CONTAINER="${GATE_PG_CONTAINER:-local-postgres-1}"
GATE_CLOCK_BOUND=10

# gate_clock_eval <step>: sets GATE_CLOCK_MSG (empty when fine) and returns 0 ok, 1 skewed or unreadable.
gate_clock_eval() {
  local step="$1" timeout="${GATE_CLOCK_TIMEOUT:-15}" tmp pid i polls m1 m2 c d ad n dir timedout=0
  GATE_CLOCK_MSG=""
  case "$timeout" in '' | *[!0-9]*) timeout=15 ;; esac
  [ "$timeout" -gt 0 ] || timeout=15
  tmp="$(mktemp "${TMPDIR:-/tmp}/gate-clock.XXXXXX")" || { GATE_CLOCK_MSG="FAIL docker clock ($step): could not read the Docker clock (no temp file)"; return 1; }
  m1="$(date -u +%s)"
  docker exec "$GATE_PG_CONTAINER" date -u +%s >"$tmp" 2>/dev/null &
  pid=$!
  polls=$((timeout * 5))
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$polls" ]; do
    sleep 0.2
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    timedout=1
    kill -KILL "$pid" 2>/dev/null
  fi
  { wait "$pid"; } 2>/dev/null
  m2="$(date -u +%s)"
  c="$(tr -d '[:space:]' <"$tmp" 2>/dev/null)"
  rm -f "$tmp"
  if [ "$timedout" -eq 1 ]; then
    GATE_CLOCK_MSG="FAIL docker clock ($step): could not read the Docker clock within $timeout s"
    return 1
  fi
  case "$c" in
    '' | *[!0-9]*) GATE_CLOCK_MSG="FAIL docker clock ($step): could not read the Docker clock (docker exec on $GATE_PG_CONTAINER failed or printed no number)"; return 1 ;;
  esac
  case "$m1$m2" in *[!0-9]*) GATE_CLOCK_MSG="FAIL docker clock ($step): could not read the Mac clock"; return 1 ;; esac
  d=$((2 * c - m1 - m2))
  GATE_CLOCK_SKEW_X2="$d"
  ad=$d
  [ "$ad" -lt 0 ] && ad=$((-ad))
  if [ "$ad" -gt $((2 * GATE_CLOCK_BOUND)) ]; then
    n=$(((ad + 1) / 2))
    if [ "$d" -lt 0 ]; then dir="behind"; else dir="ahead of"; fi
    GATE_CLOCK_MSG="FAIL docker clock ($step): Docker is $n s $dir the Mac"
    return 1
  fi
  return 0
}

# gate_clock_check <step>: see the header. Never wrap it in $( ).
gate_clock_check() {
  local step="$1"
  if gate_clock_eval "$step"; then
    log "docker clock ok ($step)"
    return 0
  fi
  echo "$GATE_CLOCK_MSG"
  log "$GATE_CLOCK_MSG"
  log "The Docker VM clock and the Mac clock must agree within ${GATE_CLOCK_BOUND} s, or time-based tests fail for no product reason (wave 54). What to do: make sure no agent is running, run 'orb stop && orb start', compare 'date -u' with 'docker exec $GATE_PG_CONTAINER date -u', then run the gate again. If the clock could not be read, check that $GATE_PG_CONTAINER is running (cd invai-infra/local && docker compose up -d)."
  echo "log: $LOG_FILE"
  exit 1
}

# Run directly (`bash scripts/gate/clock.sh`): one read-only probe of the real Docker, prints the skew.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  LOG_FILE="${LOG_FILE:-/dev/null}"
  log() { :; }
  if gate_clock_eval "manual"; then
    echo "docker clock ok: skew $((GATE_CLOCK_SKEW_X2 / 2)) s (2c-m1-m2 = ${GATE_CLOCK_SKEW_X2}, bound ${GATE_CLOCK_BOUND} s, container $GATE_PG_CONTAINER)"
  else
    echo "$GATE_CLOCK_MSG"
    exit 1
  fi
fi
