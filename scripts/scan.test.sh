#!/usr/bin/env bash
# Tests for the scan machinery (T-31-4): `pnpm scan:test`. Needs python3; the last case also needs
# Docker (BuildKit). Does not run any scanner image and touches no repo.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="python3 $INFRA_DIR/scan/ignores.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { failn=$((failn + 1)); echo "FAIL - $1"; }
expect_rc() { # want desc cmd...
  local want="$1" desc="$2"; shift 2
  "$@" >"$T/out" 2>&1; local rc=$?
  if [ "$rc" = "$want" ]; then ok "$desc"; else bad "$desc (rc=$rc, wanted $want): $(tail -n 3 "$T/out" | tr '\n' ' ')"; fi
}

# 1. the real ignore file is valid today and fails once its dates pass
expect_rc 0 "ignores.json valid today" $PY check "$INFRA_DIR/scan/ignores.json"
expect_rc 1 "ignores.json fails after its expiry dates" $PY check "$INFRA_DIR/scan/ignores.json" --today 2031-01-01
cat >"$T/noreason.json" <<'E'
{"ignores":[{"tool":"trivy","id":"CVE-0","targets":["invai-ui"],"reason":"","owner":"x","expires":"2999-01-01"}]}
E
expect_rc 1 "an ignore without a reason fails" $PY check "$T/noreason.json"
cat >"$T/far.json" <<'E'
{"ignores":[{"tool":"trivy","id":"CVE-0","targets":["invai-ui"],"reason":"r","owner":"x","expires":"2999-01-01"}]}
E
expect_rc 1 "an ignore that expires far in the future fails" $PY check "$T/far.json"

# 2. generated tool configs carry the expiry
cat >"$T/sample.json" <<'E2'
{"ignores":[{"tool":"trivy","id":"CVE-2000-0001","targets":["invai-ui"],"reason":"sample","owner":"x","expires":"2026-11-09"}]}
E2
$PY trivy "$T/sample.json" invai-ui >"$T/t.yaml"
grep -q 'expired_at: 2026-11-09' "$T/t.yaml" && grep -q 'CVE-2000-0001' "$T/t.yaml" && ok "trivy ignore file has id and expired_at" || bad "trivy ignore file"
$PY gitleaks "$INFRA_DIR/scan/ignores.json" invai-docs >"$T/g.toml"
grep -q 'useDefault = true' "$T/g.toml" && grep -q 'targetRules' "$T/g.toml" && ok "gitleaks config extends defaults and scopes by rule" || bad "gitleaks config"
$PY gitleaks "$INFRA_DIR/scan/ignores.json" invai-backend >"$T/g2.toml"
grep -q 'allowlists' "$T/g2.toml" && bad "backend must have no gitleaks allowlist" || ok "no gitleaks allowlist outside invai-docs"

# 3. workflow pin rules
W="$T/ws"; mkdir -p "$W/r1/.github/workflows" "$W/r2/.github/workflows" "$W/r3/.github/workflows"
SHA="11d5960a326750d5838078e36cf38b85af677262"
printf 'name: a\non: push\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@%s # v4\n' "$SHA" >"$W/r1/.github/workflows/a.yml"
printf 'name: a\non: push\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n' >"$W/r2/.github/workflows/a.yml"
printf 'name: a\non: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@%s # v4\n' "$SHA" >"$W/r3/.github/workflows/a.yml"
expect_rc 0 "pinned action with permissions passes" $PY pins "$W" r1
expect_rc 1 "tag-pinned action fails" $PY pins "$W" r2
expect_rc 1 "workflow without top-level permissions fails" $PY pins "$W" r3

# 4. the real workspace: every workflow today passes the pin rules
expect_rc 0 "all real workflows are SHA-pinned with permissions" $PY pins "$(cd "$INFRA_DIR/.." && pwd)" invai-contracts invai-ui invai-backend invai-web invai-floor invai-imaging invai-infra

# 4b. fail closed (S-63): a scan that looked at nothing must not read as clean
printf '{"ArtifactName":"/src","ArtifactType":"filesystem"}' >"$T/empty.json"
printf '{"Results":[{"Target":"package.json","Class":"lang-pkgs"}]}' >"$T/wrong.json"
printf '{"Results":[{"Target":"pnpm-lock.yaml","Class":"lang-pkgs"}]}' >"$T/good.json"
printf '{"Results":[{"Target":"sub/uv.lock","Class":"lang-pkgs"}]}' >"$T/nested.json"
printf '{"Results":[{"Target":"x (debian 12.15)","Class":"os-pkgs"}]}' >"$T/img.json"
printf '{"Results":[{"Target":"Node.js","Class":"lang-pkgs"}]}' >"$T/img-noos.json"
expect_rc 1 "trivy result with no Results (empty export) fails" $PY expect "$T/empty.json" file pnpm-lock.yaml
expect_rc 1 "missing lockfile target fails" $PY expect "$T/wrong.json" file pnpm-lock.yaml
expect_rc 0 "normal lockfile result passes" $PY expect "$T/good.json" file pnpm-lock.yaml
expect_rc 0 "nested lockfile target passes" $PY expect "$T/nested.json" file uv.lock
expect_rc 1 "unreadable trivy output fails" $PY expect "$T/nope.json" file pnpm-lock.yaml
expect_rc 1 "image result without OS packages fails" $PY expect "$T/img-noos.json" image
expect_rc 0 "normal image result passes" $PY expect "$T/img.json" image
# scan.sh itself: an empty export and a repo without its lockfile stop the deps step
if docker info >/dev/null 2>&1; then
  E="$T/emptyws"; mkdir -p "$E/invai-contracts"; git -C "$E/invai-contracts" init -q
  SCAN_WORKSPACE="$E" SCAN_OUT="$T/out-e" bash "$SCRIPT_DIR/scan.sh" deps >"$T/e.out" 2>&1; rc=$?
  [ "$rc" != "0" ] && grep -q 'nothing to scan\|could not export' "$T/e.out" && ok "scan.sh deps fails on an empty export" || bad "empty export did not fail (rc=$rc): $(tail -n 3 "$T/e.out" | tr '\n' ' ')"
  L="$T/nolockws"; mkdir -p "$L/invai-contracts"; git -C "$L/invai-contracts" init -q; echo '{}' >"$L/invai-contracts/package.json"
  SCAN_WORKSPACE="$L" SCAN_OUT="$T/out-l" bash "$SCRIPT_DIR/scan.sh" deps >"$T/l.out" 2>&1; rc=$?
  [ "$rc" != "0" ] && grep -q 'pnpm-lock.yaml is missing' "$T/l.out" && ok "scan.sh deps fails when the lockfile is missing" || bad "missing lockfile did not fail (rc=$rc): $(tail -n 3 "$T/l.out" | tr '\n' ' ')"
fi

# 5. the BuildKit canary catches an ignore file that lets .env through (needs Docker)
if docker info >/dev/null 2>&1; then
  F="$T/fake"; mkdir -p "$F/invai-backend"
  printf '*\n!invai-backend\n' >"$F/invai-backend/Dockerfile.dockerignore"
  SCAN_WORKSPACE="$F" SCAN_OUT="$T/out-scan" bash "$SCRIPT_DIR/scan.sh" hardening >"$T/h.out" 2>&1
  grep -q 'FAIL invai-backend: Dockerfile.dockerignore re-allows\|FAIL canary invai-backend' "$T/h.out" && ok "permissive Dockerfile.dockerignore is rejected" || bad "permissive ignore file not rejected: $(grep -i backend "$T/h.out" | head -n 3 | tr '\n' ' ')"
  printf '*\n!invai-backend/src\n**/node_modules\n**/.git\n**/.env\n**/.env.*\n**/seed-output.json\n**/e2e\n**/*.test.ts\n' >"$F/invai-backend/Dockerfile.dockerignore"
  SCAN_WORKSPACE="$F" SCAN_OUT="$T/out-scan" bash "$SCRIPT_DIR/scan.sh" hardening >"$T/h2.out" 2>&1
  grep -q 'canary invai-backend: planted' "$T/h2.out" && ok "strict Dockerfile.dockerignore passes the canary" || bad "strict ignore file failed canary: $(grep -i 'backend' "$T/h2.out" | head -n 3 | tr '\n' ' ')"
else
  echo "skip - canary cases (docker not reachable)"
fi

echo "$pass passed, $failn failed"
[ "$failn" = "0" ]
