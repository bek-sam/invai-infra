#!/usr/bin/env bash
# Ordering check for the gate's golden-path block (B-321): no worker/api runs while db:reset,
# migrate and seed run. Static: reads the order of calls in gate.sh (or the file given as $1).
set -uo pipefail
SRC="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gate.sh}"
line() { grep -n "$1" "$SRC" | head -n 1 | cut -d: -f1; }
imaging="$(line 'img_pgid="$(start_imaging)"')"
reset="$(line 'pnpm db:reset')"
first_dev="$(line 'start_dev_all)"')"
stop_img="$(line 'stop_group "$img_pgid"')"
fail=0
chk() { if [ -n "$2" ] && [ -n "$3" ] && [ "$2" -lt "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 ($2 vs $3)"; fail=1; fi; }
chk "imaging starts before the seed" "$imaging" "$reset"
chk "imaging stops after the seed, before the full stack" "$reset" "$stop_img"
chk "the full dev group starts only after the seed" "$reset" "$first_dev"
count="$(grep -c 'start_dev_all)"' "$SRC")"
[ "$count" = 1 ] && echo "ok   - dev:all is started once" || { echo "FAIL - dev:all started $count times"; fail=1; }
exit $fail
