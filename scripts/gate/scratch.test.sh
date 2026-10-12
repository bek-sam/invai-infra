#!/usr/bin/env bash
# Tests for the gate scratch-database guard and the floor seed swap (T-41-4). bash 3.2 compatible.
# No database or Valkey is touched; the swap runs in a temp workspace.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${GATE_SRC_DIR:-$(cd "$HERE/.." && pwd)}"
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

[ -f "$SRC/gate/scratch.sh" ] || { bad "scratch.sh exists"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ws/invai-backend" "$T/ws/invai-infra/.gate"
D="$T/ws/invai-backend/seed-output.json"
printf '{"dev":true}\n' >"$D"; printf '{"gate":true}\n' >"$T/ws/invai-infra/.gate/seed-output.json"
sha() { shasum -a 256 "$1" | cut -c1-64; }
before="$(sha "$D")"

env_for() { # run a snippet with lib+scratch sourced against the temp workspace
  ( export LOG_FILE="$T/log" WORKSPACE_DIR="$T/ws" INFRA_DIR="$T/ws/invai-infra" GATE_DIR="$T/ws/invai-infra/.gate"
    source "$SRC/gate/lib.sh"; source "$SRC/gate/scratch.sh"; gate_scratch_vars; eval "$1" )
}

# guard
G='postgres://invai_app:invai@localhost:5432/invai_gate'; M='postgres://invai:invai@localhost:5432/invai_gate'; R='redis://localhost:6379/9'
c() { env_for "gate_scratch_check '$1' '$2' '$3'" 2>&1; echo "rc=$?"; }
case "$(c "$G" "$M" "$R")" in *rc=0) ok "scratch URLs pass" ;; *) bad "scratch URLs pass" ;; esac
case "$(c "${G%invai_gate}invai" "$M" "$R")" in *"DATABASE_URL names"*rc=1) ok "refuses DATABASE_URL=invai" ;; *) bad "refuses DATABASE_URL=invai" ;; esac
case "$(c "$G" "${M%invai_gate}invai" "$R")" in *"MIGRATION_DATABASE_URL names"*rc=1) ok "refuses MIGRATION_DATABASE_URL=invai" ;; *) bad "refuses MIGRATION_DATABASE_URL=invai" ;; esac
case "$(c "$G" "$M" redis://localhost:6379)" in *"not Valkey DB 9"*rc=1) ok "refuses Valkey DB 0" ;; *) bad "refuses Valkey DB 0" ;; esac
case "$(c "$G" "$M" redis://localhost:6379/3)" in *rc=1) ok "refuses another agent's Valkey DB" ;; *) bad "refuses Valkey DB 3" ;; esac
case "$(env_for 'gate_scratch_env >/dev/null; echo "$DATABASE_URL $MIGRATION_DATABASE_URL $REDIS_URL $SEED_OUTPUT_FILE $E2E_SEED_OUTPUT_FILE"')" in
  *"/invai_gate "*"/invai_gate redis://localhost:6379/9 $T/ws/invai-infra/.gate/seed-output.json $T/ws/invai-infra/.gate/seed-output.json") ok "gate_scratch_env exports all five variables" ;;
  *) bad "gate_scratch_env exports all five variables" ;; esac

# paid AI
case "$(INVAI_PAID_AI=1 env_for gate_refuse_paid_ai 2>&1; echo "rc=$?")" in *"INVAI_PAID_AI is set"*rc=1) ok "refuses INVAI_PAID_AI" ;; *) bad "refuses INVAI_PAID_AI" ;; esac
case "$(IMAGE_GEN_PROVIDER=openai env_for gate_refuse_paid_ai 2>&1; echo "rc=$?")" in *"IMAGE_GEN_PROVIDER is set"*rc=1) ok "refuses IMAGE_GEN_PROVIDER" ;; *) bad "refuses IMAGE_GEN_PROVIDER" ;; esac

# swap: normal restore
env_for 'gate_swap_dev_seed; cat "$(gate_dev_seed_file)" >"$T/during"; gate_restore_dev_seed'
eq "floor sees the gate seed during the swap" "$(cat "$T/during")" '{"gate":true}'
eq "dev seed-output.json byte-identical after a normal swap" "$(sha "$D")" "$before"
# swap: forced failure through the EXIT trap
env_for 'gate_swap_dev_seed; false; exit 7' >/dev/null 2>&1
eq "dev seed-output.json restored by the trap after a failed run" "$(sha "$D")" "$before"
# swap: SIGKILL leaves the backup; the next start restores it
{ LOG_FILE="$T/log" WORKSPACE_DIR="$T/ws" INFRA_DIR="$T/ws/invai-infra" GATE_DIR="$T/ws/invai-infra/.gate" SRC="$SRC" bash -c '
  source "$SRC/gate/lib.sh"; source "$SRC/gate/scratch.sh"; gate_scratch_vars; gate_swap_dev_seed; kill -KILL $$'; } 2>/dev/null
[ -f "$T/ws/invai-infra/.gate/seed-output.dev.json" ] && ok "SIGKILL leaves the backup" || bad "SIGKILL leaves the backup"
env_for 'gate_restore_dev_seed'
eq "dev seed-output.json restored at the next start after SIGKILL" "$(sha "$D")" "$before"
[ ! -f "$T/ws/invai-infra/.gate/seed-output.dev.json" ] && ok "backup removed after restore" || bad "backup removed after restore"

# static: every db:reset in gate.sh sits after gate_scratch_env; the old dev-DB wording is gone
a="$(grep -n 'gate_scratch_env$' "$SRC/gate.sh" | head -n1 | cut -d: -f1)"; r="$(grep -n 'pnpm db:reset' "$SRC/gate.sh" | head -n1 | cut -d: -f1)"
[ -n "$a" ] && [ -n "$r" ] && [ "$a" -lt "$r" ] && ok "scratch env is exported before db:reset" || bad "scratch env is exported before db:reset ($a vs $r)"
exit $fail
