#!/usr/bin/env bash
# Tests for scripts/gate/ports.sh and its use in gate.sh / lib.sh / dev.sh (T-36-1, B-361).
# bash 3.2 compatible. GATE_SRC_DIR (default: this repo's scripts/) lets the static checks run
# against an older checkout to prove them red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${GATE_SRC_DIR:-$(cd "$HERE/.." && pwd)}"
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing '$2' in '$3')" ;; esac; }

# run <env assignments...> -- evaluates resolve_ports in a clean shell and prints the result vars
run() {
  env -i PATH="$PATH" HOME="$HOME" "$@" bash -c '
    source "'"$HERE"'/ports.sh" || exit 99
    resolve_ports; rc=$?
    echo "rc=$rc"
    echo "err=$PORT_ERROR"
    echo "ports=$API_PORT/$IMAGING_PORT/$WEB_PORT/$FLOOR_PORT"
    for v in PORT BETTER_AUTH_URL IMAGING_URL WEB_ORIGIN FLOOR_ORIGIN E2E_API_URL E2E_WEB_URL E2E_FLOOR_URL VITE_API_URL VITE_API_PROXY; do
      eval "[ -n \"\${$v+x}\" ] && echo \"$v=\${$v}\""
    done
    exit 0
  ' 2>&1
}
val() { printf '%s\n' "$1" | grep "^$2=" | head -n 1 | cut -d= -f2-; }

if [ ! -f "$HERE/ports.sh" ]; then bad "scripts/gate/ports.sh exists"; exit 1; fi

# 1 defaults: ports and no exported variable
out="$(run X=1)"
eq "defaults: rc 0" "$(val "$out" rc)" 0
eq "defaults: 3000/8000/5173/5174" "$(val "$out" ports)" "3000/8000/5173/5174"
exported="$(printf '%s\n' "$out" | grep -E '^(PORT|BETTER_AUTH_URL|IMAGING_URL|WEB_ORIGIN|FLOOR_ORIGIN|E2E_[A-Z]+_URL|VITE_[A-Z_]+)=' || true)"
eq "defaults: nothing new exported" "$exported" ""

# 2 overrides
out="$(run INVAI_IMAGING_PORT=8100 INVAI_WEB_PORT=5183)"
eq "override: ports" "$(val "$out" ports)" "3000/8100/5183/5174"
eq "override: IMAGING_URL" "$(val "$out" IMAGING_URL)" "http://localhost:8100"
eq "override: WEB_ORIGIN" "$(val "$out" WEB_ORIGIN)" "http://localhost:5183"
eq "override: E2E_WEB_URL" "$(val "$out" E2E_WEB_URL)" "http://localhost:5183"
eq "override: PORT not exported (api unset)" "$(val "$out" PORT)" ""
eq "override: FLOOR_ORIGIN not exported (floor unset)" "$(val "$out" FLOOR_ORIGIN)" ""
out="$(run INVAI_API_PORT=3105 INVAI_FLOOR_PORT=5190)"
eq "api override: PORT" "$(val "$out" PORT)" 3105
eq "api override: BETTER_AUTH_URL" "$(val "$out" BETTER_AUTH_URL)" "http://localhost:3105"
eq "api override: E2E_API_URL" "$(val "$out" E2E_API_URL)" "http://localhost:3105"
eq "floor override: FLOOR_ORIGIN" "$(val "$out" FLOOR_ORIGIN)" "http://localhost:5190"
eq "floor override: E2E_FLOOR_URL" "$(val "$out" E2E_FLOOR_URL)" "http://localhost:5190"
eq "VITE_API_URL never exported globally" "$(val "$out" VITE_API_URL)" ""
eq "VITE_API_PROXY never exported globally" "$(val "$out" VITE_API_PROXY)" ""

# 5 invalid values
for bad_val in abc 80 1023 65536 8000.5 -5 "08000"; do
  out="$(run INVAI_IMAGING_PORT="$bad_val")"
  eq "invalid '$bad_val' refused" "$(val "$out" rc)" 1
done
out="$(run INVAI_IMAGING_PORT=70000)"
has "invalid message names the variable" "INVAI_IMAGING_PORT" "$(val "$out" err)"
out="$(run INVAI_WEB_PORT=3000)"
eq "duplicate with the default api port refused" "$(val "$out" rc)" 1
has "duplicate message names both variables" "INVAI_API_PORT and INVAI_WEB_PORT" "$(val "$out" err)"
out="$(run INVAI_IMAGING_PORT=5200 INVAI_WEB_PORT=5200)"
eq "explicit duplicate refused" "$(val "$out" rc)" 1
for r in 5432 6379 9000 9001 1025 8025 54322; do
  out="$(run INVAI_WEB_PORT=$r)"
  eq "reserved port $r refused" "$(val "$out" rc)" 1
done

# 4 busy port: a listener this test starts (and stops) on a free port
lfile="$(mktemp)"
python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(1)
print(s.getsockname()[1], flush=True)
time.sleep(60)
' >"$lfile" &
lpid=$!
trap 'kill "$lpid" 2>/dev/null; rm -f "$lfile"' EXIT
busy=""
for _ in 1 2 3 4 5 6 7 8 9 10; do busy="$(head -n 1 "$lfile")"; [ -n "$busy" ] && break; sleep 0.3; done
if [ -z "$busy" ] || [ "$busy" -lt 1024 ]; then
  bad "test listener started on an unprivileged port (got '$busy')"
else
  msg="$(env -i PATH="$PATH" HOME="$HOME" INVAI_IMAGING_PORT="$busy" bash -c '
    source "'"$HERE"'/ports.sh"; resolve_ports || exit 99
    first_busy_port_message; echo "rc=$?"' 2>&1)"
  has "busy: names the port" "port $busy is held by pid $lpid" "$msg"
  has "busy: names the env var" "set INVAI_IMAGING_PORT to a free port" "$msg"
  has "busy: says it was not started by the gate" "not started by this gate" "$msg"
  has "busy: returns 0" "rc=0" "$msg"
  kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null
  msg="$(env -i PATH="$PATH" HOME="$HOME" INVAI_IMAGING_PORT="$busy" INVAI_API_PORT=3187 INVAI_WEB_PORT=5187 INVAI_FLOOR_PORT=5188 bash -c '
    source "'"$HERE"'/ports.sh"; resolve_ports || exit 99
    first_busy_port_message; echo "rc=$?"' 2>&1)"
  has "free ports: no message, returns 1" "rc=1" "$msg"
fi

# static: the scripts use the variables, no pinned ports left
pins="$(grep -nE 'localhost:(3000|8000|5173|5174)|--port 8000|for p in 3000' "$SRC/gate.sh" "$SRC/gate/lib.sh" "$SRC/dev.sh" | grep -v '^.*:[0-9]*:\s*#' | grep -vE 'VITE_API_URL:-http://localhost:\$API_PORT' || true)"
eq "no pinned default ports in gate.sh, lib.sh, dev.sh" "$pins" ""
grep -q 'resolve_ports' "$SRC/gate.sh" && ok "gate.sh resolves ports" || bad "gate.sh resolves ports"
grep -q 'resolve_ports' "$SRC/dev.sh" && ok "dev.sh resolves ports" || bad "dev.sh resolves ports"
grep -q -- '--strictPort' "$SRC/dev.sh" && ok "dev.sh passes --strictPort" || bad "dev.sh passes --strictPort"
# VITE vars are scoped to one command each
grep -q 'invai-web && ${web_env}pnpm dev' "$SRC/dev.sh" && grep -q 'invai-floor && ${floor_env}pnpm dev' "$SRC/dev.sh" \
  && ok "dev.sh scopes VITE vars per command" || bad "dev.sh scopes VITE vars per command"
exit $fail
