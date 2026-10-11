#!/usr/bin/env bash
# Port configuration shared by scripts/dev.sh and scripts/gate.sh (T-36-1, B-361). Sourced.
#
#   INVAI_API_PORT (3000)  INVAI_IMAGING_PORT (8000)  INVAI_WEB_PORT (5173)  INVAI_FLOOR_PORT (5174)
#
# resolve_ports validates the resolved values (defaults included) and sets API_PORT, IMAGING_PORT,
# WEB_PORT, FLOOR_PORT. It exports the backend/E2E variables ONLY for an INVAI_*_PORT that is set,
# so with none set nothing new reaches the environment and invai-backend/.env keeps governing.
# VITE_API_URL (web) and VITE_API_PROXY (floor) are never exported: floor reads a set VITE_API_URL
# as an absolute API and its dev CSP would then block every call. dev.sh scopes them per command.
# On failure it sets PORT_ERROR (one line) and returns 1; the caller decides how to exit.

# Local infra and neighbour projects: never valid app ports.
INVAI_RESERVED_PORTS="5432 6379 9000 9001 1025 8025 54322"

_resolve_one() { # <var name> <default> <result var>
  local name="$1" def="$2" out="$3" val
  val="${!name:-}"
  if [ -z "$val" ]; then
    printf -v "$out" '%s' "$def"
    return 0
  fi
  case "$val" in
    [1-9][0-9][0-9][0-9] | [1-9][0-9][0-9][0-9][0-9]) ;;
    *) PORT_ERROR="$name='$val' is not a port number; use an integer from 1024 to 65535"; return 1 ;;
  esac
  if [ "$val" -lt 1024 ] || [ "$val" -gt 65535 ]; then
    PORT_ERROR="$name=$val is out of range; use an integer from 1024 to 65535"
    return 1
  fi
  printf -v "$out" '%s' "$val"
}

resolve_ports() {
  PORT_ERROR=""
  _resolve_one INVAI_API_PORT 3000 API_PORT || return 1
  _resolve_one INVAI_IMAGING_PORT 8000 IMAGING_PORT || return 1
  _resolve_one INVAI_WEB_PORT 5173 WEB_PORT || return 1
  _resolve_one INVAI_FLOOR_PORT 5174 FLOOR_PORT || return 1

  local pair a b na nb r
  for pair in "INVAI_API_PORT:$API_PORT:INVAI_IMAGING_PORT:$IMAGING_PORT" \
              "INVAI_API_PORT:$API_PORT:INVAI_WEB_PORT:$WEB_PORT" \
              "INVAI_API_PORT:$API_PORT:INVAI_FLOOR_PORT:$FLOOR_PORT" \
              "INVAI_IMAGING_PORT:$IMAGING_PORT:INVAI_WEB_PORT:$WEB_PORT" \
              "INVAI_IMAGING_PORT:$IMAGING_PORT:INVAI_FLOOR_PORT:$FLOOR_PORT" \
              "INVAI_WEB_PORT:$WEB_PORT:INVAI_FLOOR_PORT:$FLOOR_PORT"; do
    IFS=: read -r na a nb b <<<"$pair"
    if [ "$a" = "$b" ]; then
      PORT_ERROR="$na and $nb both resolve to port $a; give each service its own port"
      return 1
    fi
  done
  for pair in "INVAI_API_PORT:$API_PORT" "INVAI_IMAGING_PORT:$IMAGING_PORT" \
              "INVAI_WEB_PORT:$WEB_PORT" "INVAI_FLOOR_PORT:$FLOOR_PORT"; do
    IFS=: read -r na a <<<"$pair"
    for r in $INVAI_RESERVED_PORTS; do
      if [ "$a" = "$r" ]; then
        PORT_ERROR="$na resolves to port $a, which belongs to local infra or another project; pick another port"
        return 1
      fi
    done
  done

  if [ -n "${INVAI_API_PORT:-}" ]; then
    export PORT="$API_PORT" BETTER_AUTH_URL="http://localhost:$API_PORT" E2E_API_URL="http://localhost:$API_PORT"
  fi
  if [ -n "${INVAI_IMAGING_PORT:-}" ]; then
    export IMAGING_URL="http://localhost:$IMAGING_PORT"
  fi
  if [ -n "${INVAI_WEB_PORT:-}" ]; then
    export WEB_ORIGIN="http://localhost:$WEB_PORT" E2E_WEB_URL="http://localhost:$WEB_PORT"
  fi
  if [ -n "${INVAI_FLOOR_PORT:-}" ]; then
    export FLOOR_ORIGIN="http://localhost:$FLOOR_PORT" E2E_FLOOR_URL="http://localhost:$FLOOR_PORT"
  fi
  return 0
}

# first_busy_port_message: prints one refusal line for the first configured port that something
# is listening on, and returns 0; prints nothing and returns 1 when all four are free. Tests the
# lsof output for emptiness, not its exit code (lsof exits 1 on "nothing found").
first_busy_port_message() {
  local pair p var pid
  for pair in "$API_PORT:INVAI_API_PORT" "$IMAGING_PORT:INVAI_IMAGING_PORT" \
              "$WEB_PORT:INVAI_WEB_PORT" "$FLOOR_PORT:INVAI_FLOOR_PORT"; do
    p="${pair%%:*}"
    var="${pair#*:}"
    pid="$(lsof -nP -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
    if [ -n "$pid" ]; then
      echo "port $p is held by pid $pid (not started by this gate); stop it or set $var to a free port"
      return 0
    fi
  done
  return 1
}
