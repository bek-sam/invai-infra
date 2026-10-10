#!/usr/bin/env bash
# Tests for contracts-check.sh (T-32-4). Run: `pnpm contracts:check:test`.
# Builds throwaway copies of invai-contracts under a temp dir (src, package.json, CHANGELOG.md,
# node_modules symlinked to the real one) and checks exit codes and output for AC 1-4.
# `--mutants` runs the same cases against two broken copies of the script (typecheck disabled,
# version check disabled) and requires that the suite then FAILS, proving the cases bite.
# Env CONTRACTS_CHECK_SCRIPT overrides the script under test. bash 3.2 compatible.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAL="$WORKSPACE_DIR/invai-contracts"
SCRIPT="${CONTRACTS_CHECK_SCRIPT:-$SCRIPT_DIR/contracts-check.sh}"
export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/share/pnpm:$PATH"

if [ "${1:-}" = "--mutants" ]; then
  M="$(mktemp -d "${TMPDIR:-/tmp}/cc-mutants.XXXXXX")"
  trap 'rm -rf "$M"' EXIT
  sed 's|out="$(cd "$repo" \&\& "$repo/node_modules/.bin/tsc".*|out=""|' "$SCRIPT_DIR/contracts-check.sh" >"$M/no-tsc.sh"
  sed 's|^if git -C "$CONTRACTS_DIR" rev-parse --is-inside-work-tree|if false \&\& git -C "$CONTRACTS_DIR" rev-parse --is-inside-work-tree|' "$SCRIPT_DIR/contracts-check.sh" >"$M/no-version.sh"
  for f in no-tsc no-version; do
    cmp -s "$SCRIPT_DIR/contracts-check.sh" "$M/$f.sh" && { echo "mutant $f did not change the script"; exit 2; }
    # the mutant lives next to a copy of nothing else: it derives its paths from its own location
    mkdir -p "$M/$f/scripts" && cp "$M/$f.sh" "$M/$f/scripts/contracts-check.sh"
  done
  # mutants resolve WORKSPACE_DIR from their own location, so point them at the real infra dir
  for f in no-tsc no-version; do
    sed -i.bak "s|^INFRA_DIR=.*|INFRA_DIR=\"$SCRIPT_DIR/..\"|" "$M/$f/scripts/contracts-check.sh"
    echo "== mutant: $f (the suite must FAIL)"
    CONTRACTS_CHECK_SCRIPT="$M/$f/scripts/contracts-check.sh" bash "${BASH_SOURCE[0]}" 2>&1 | grep -E '^(ok|not ok|--)' 
    rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 0 ]; then echo "MUTANT SURVIVED: $f"; exit 1; fi
    echo "mutant $f killed (suite exit $rc)"
  done
  exit 0
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/cc-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fails=$((fails + 1)); }

mkcopy() { # mkcopy <name>: a copy without .git
  local d="$T/$1"
  mkdir -p "$d"
  cp -R "$REAL/src" "$REAL/package.json" "$REAL/CHANGELOG.md" "$d/"
  ln -s "$REAL/node_modules" "$d/node_modules"
  echo "$d"
}

run() { # run <dir...>: sets OUT and RC
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

snapshot() {
  local c
  for c in backend web floor ui; do
    echo "$c: $(git -C "$WORKSPACE_DIR/invai-$c" status --short | shasum | cut -c1-12) $(readlink "$WORKSPACE_DIR/invai-$c/node_modules/@invai/contracts" 2>/dev/null)"
  done
}
BEFORE="$(snapshot)"

# AC1: clean tree (real default dir)
run
if [ $RC -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^PASS ')" -eq 4 ] && printf '%s' "$OUT" | grep -q 'contracts [0-9]'; then
  ok "AC1 clean default tree: exit 0, 4 PASS lines with the version"
else bad "AC1 clean default tree (rc=$RC) $OUT"; fi

# AC2: breaking change (rename an output field consumers read)
D="$(mkcopy breaking)"
perl -0pi -e 's/orderNo: z\.string\(\),/orderNumber: z.string(),/' "$D/src/schemas/orders.ts"
run --contracts "$D"
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -Eq '^FAIL (backend|web)'; then
  ok "AC2 renamed output field: exit 1, names failing consumers ($(printf '%s\n' "$OUT" | grep -c '^FAIL ') FAIL lines)"
else bad "AC2 renamed output field (rc=$RC) $(printf '%s' "$OUT" | head -5)"; fi

# AC3: additive optional output field passes
D="$(mkcopy additive)"
perl -0pi -e 's/orderNo: z\.string\(\),/orderNo: z.string(),\n  ccTestOptional: z.string().optional(),/' "$D/src/schemas/orders.ts"
run --contracts "$D"
if [ $RC -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^PASS ')" -eq 4 ]; then
  ok "AC3 additive optional field: exit 0"
else bad "AC3 additive optional field (rc=$RC) $(printf '%s' "$OUT" | head -5)"; fi

# AC4: version and changelog (needs a git work tree)
V="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$REAL/package.json" | head -1)"
G() { git -C "$1" -c user.name=t -c user.email=t@example.test "${@:2}" >/dev/null 2>&1; }
D="$(mkcopy warn)"
G "$D" init -q; printf 'node_modules\n' >"$D/.gitignore"; G "$D" add -A; G "$D" commit -qm base
printf '\nexport const ccTouched = 1;\n' >>"$D/src/index.ts"
sed -i.bak "s/^## $V/## Unreleased/" "$D/CHANGELOG.md"; rm -f "$D/CHANGELOG.md.bak"
run --contracts "$D"
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q "^WARN .*$V"; then ok "AC4a src changed, no heading: WARN naming $V, exit 0"
else bad "AC4a (rc=$RC) $(printf '%s' "$OUT" | grep -c WARN) WARN lines"; fi

D="$(mkcopy heading)"
G "$D" init -q; printf 'node_modules\n' >"$D/.gitignore"; G "$D" add -A; G "$D" commit -qm base
printf '\nexport const ccTouched = 1;\n' >>"$D/src/index.ts"
run --contracts "$D"
if [ $RC -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^WARN'; then ok "AC4b src changed, heading present: no WARN"
else bad "AC4b (rc=$RC) $(printf '%s' "$OUT" | grep WARN)"; fi

D="$(mkcopy nodiff)"
G "$D" init -q; printf 'node_modules\n' >"$D/.gitignore"; G "$D" add -A; G "$D" commit -qm base
sed -i.bak "s/^## $V/## Unreleased/" "$D/CHANGELOG.md"; rm -f "$D/CHANGELOG.md.bak"
run --contracts "$D"
if [ $RC -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^WARN'; then ok "AC4c src unchanged since version commit: no WARN"
else bad "AC4c (rc=$RC)"; fi

# setup errors exit 2
run --contracts "$T/does-not-exist"
if [ $RC -eq 2 ]; then ok "missing dir: exit 2"; else bad "missing dir (rc=$RC)"; fi
D="$T/nonm"; mkdir -p "$D/src"; cp "$REAL/src/index.ts" "$D/src/"; cp "$REAL/package.json" "$D/"
run --contracts "$D"
if [ $RC -eq 2 ]; then ok "no node_modules: exit 2"; else bad "no node_modules (rc=$RC)"; fi

# consumers untouched
AFTER="$(snapshot)"
if [ "$BEFORE" = "$AFTER" ]; then ok "consumers' git status and contracts link unchanged"
else bad "consumer state changed during the run (another agent may be editing): $(diff <(echo "$BEFORE") <(echo "$AFTER"))"; fi

[ "$fails" -eq 0 ] && echo "all cases passed" || echo "$fails case(s) failed"
[ "$fails" -eq 0 ]
