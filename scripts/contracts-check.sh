#!/usr/bin/env bash
# Typecheck every consumer (backend, web, floor, ui) against a contracts tree (T-32-4, B-83).
#
# Usage: pnpm contracts:check [--contracts <dir>]      (default <dir> = ../invai-contracts)
# Exit 0: all consumers typecheck. Exit 1: names each failing consumer with its first 20 error
# lines. Exit 2: usage or setup error (missing dir, no node_modules).
#
# How: consumers resolve `@invai/contracts` through a `link:` to the package's `exports "."` ->
# ./src/index.ts. For each consumer we write a throwaway tsconfig in a temp dir that extends the
# consumer's own tsconfig and adds `paths: {"@invai/contracts": ["<dir>/src/index.ts"]}`, then
# run the consumer's own `tsc -p`. Nothing inside any repo is written, linked or restored.
# <dir> needs its own node_modules (zod, @orpc); a throwaway copy symlinks invai-contracts's.
#
# bash 3.2 compatible (no mapfile, no associative arrays).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$INFRA_DIR/.." && pwd)"
export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/share/pnpm:$PATH"

CONSUMERS="backend web floor ui"
CONTRACTS_DIR="$WORKSPACE_DIR/invai-contracts"

usage_error() {
  echo "contracts-check: $1" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --contracts)
      [ "$#" -ge 2 ] || usage_error "--contracts needs a directory"
      CONTRACTS_DIR="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,8p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) usage_error "unknown argument '$1' (usage: contracts-check.sh [--contracts <dir>])" ;;
  esac
done

[ -d "$CONTRACTS_DIR" ] || usage_error "contracts dir not found: $CONTRACTS_DIR"
CONTRACTS_DIR="$(cd "$CONTRACTS_DIR" && pwd -P)"
[ -f "$CONTRACTS_DIR/src/index.ts" ] || usage_error "no src/index.ts in $CONTRACTS_DIR"
[ -f "$CONTRACTS_DIR/package.json" ] || usage_error "no package.json in $CONTRACTS_DIR"
[ -e "$CONTRACTS_DIR/node_modules" ] || usage_error "no node_modules in $CONTRACTS_DIR (zod/@orpc would not resolve; symlink invai-contracts/node_modules into a copy)"

for c in $CONSUMERS; do
  repo="$WORKSPACE_DIR/invai-$c"
  [ -f "$repo/tsconfig.json" ] || usage_error "invai-$c has no tsconfig.json"
  [ -x "$repo/node_modules/.bin/tsc" ] || usage_error "invai-$c has no node_modules/.bin/tsc (run pnpm install there)"
done

VERSION="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONTRACTS_DIR/package.json" | head -1)"
[ -n "$VERSION" ] || usage_error "no version in $CONTRACTS_DIR/package.json"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/contracts-check.XXXXXX")" || usage_error "cannot create temp dir"
trap 'rm -rf "$TMP"' EXIT

failed=0
for c in $CONSUMERS; do
  repo="$WORKSPACE_DIR/invai-$c"
  cfg="$TMP/tsconfig.$c.json"
  # typeRoots: a tsconfig outside the repo would otherwise look for @types next to itself.
  cat >"$cfg" <<EOF
{
  "extends": "$repo/tsconfig.json",
  "compilerOptions": {
    "typeRoots": ["$repo/node_modules/@types"],
    "paths": { "@invai/contracts": ["$CONTRACTS_DIR/src/index.ts"] }
  }
}
EOF
  out="$(cd "$repo" && "$repo/node_modules/.bin/tsc" --noEmit -p "$cfg" 2>&1)"
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "PASS $c (contracts $VERSION)"
  else
    failed=1
    echo "FAIL $c (contracts $VERSION), first 20 error lines:"
    printf '%s\n' "$out" | head -n 20 | cut -c1-300 | sed 's/^/  /'
  fi
done

# ---------- version and changelog (warning only) ----------
# Only when <dir> is a git work tree. If src/ differs from the last commit that changed the
# `"version"` line of package.json and CHANGELOG.md has no `## <version>` heading, warn.
if git -C "$CONTRACTS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git -C "$CONTRACTS_DIR" rev-parse --show-toplevel 2>/dev/null)" = "$CONTRACTS_DIR" ]; then
  vsha="$(git -C "$CONTRACTS_DIR" log --root -1 --format=%H -G'^[[:space:]]*"version":' -- package.json 2>/dev/null)"
  if [ -n "$vsha" ]; then
    if ! git -C "$CONTRACTS_DIR" diff --quiet "$vsha" -- src 2>/dev/null \
        || [ -n "$(git -C "$CONTRACTS_DIR" ls-files --others --exclude-standard -- src 2>/dev/null)" ]; then
      if ! grep -Eq "^## ${VERSION//./\\.}([[:space:]]|\$)" "$CONTRACTS_DIR/CHANGELOG.md" 2>/dev/null; then
        echo "WARN contracts src/ changed since the version $VERSION commit (${vsha:0:7}) and CHANGELOG.md has no '## $VERSION' heading"
      fi
    fi
  fi
fi

[ "$failed" -eq 0 ] || exit 1
exit 0
