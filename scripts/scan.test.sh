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

# 6. the blank-key docs ignore is anchored (B-318, S-64): only a pair of EMPTY assignments is
# skipped; a real token on the same line must still be reported. Runs the pinned gitleaks image
# against the generated config. $1 = ignores file. Prints the number of findings per case file.
# Lines are built from pieces so this file never holds a blank-key command or a token itself.
gl_cases() {
  local ign="$1" d="$T/glcase-$2" k1="OPENAI_API""_KEY" k2="ANTHROPIC_API""_KEY" tok="Qx7pL2mVn9Rt4KsB8wZc3HjD5fY"
  rm -rf "$d"; mkdir -p "$d/src/waves"
  printf 'run with %s= %s= caffeinate -i pnpm gate and E2E_API=1 afterwards\n' "$k1" "$k2" >"$d/src/waves/blank.md"
  printf '%s= %s=%s\n' "$k1" "$k2" "$tok" >"$d/src/waves/token-second.md"
  printf '%s= %s= FOO=%s\n' "$k1" "$k2" "$tok" >"$d/src/waves/token-foo.md"
  python3 "$INFRA_DIR/scan/ignores.py" gitleaks "$ign" invai-docs >"$d/gl.toml"
  local img; img="$(sed -n 's/^GITLEAKS_IMAGE=//p' "$INFRA_DIR/scan/tools.env")"
  docker run --rm -v "$d/src:/src:ro" -v "$d:/out" "$img" dir /src -c /out/gl.toml --redact --no-banner -f json -r /out/r.json --exit-code 0 >/dev/null 2>&1
  python3 - "$d/r.json" <<'PYE'
import json, sys
f = {r["File"].rsplit("/", 1)[-1] for r in json.load(open(sys.argv[1]))}
print(" ".join(sorted(f)))
PYE
}
if docker info >/dev/null 2>&1; then
  python3 - "$INFRA_DIR/scan/ignores.json" "$T/old-ignores.json" <<'PYO'
import json, sys
old = json.load(open(sys.argv[1]))
# the pre-B-318 regex, kept only to prove the new cases are red on it
old["ignores"][0]["line_regex"] = '(OPENAI_API_KEY=\\s+ANTHROPIC_API_KEY=|STRIPE_WEBHOOK_SECRET=" ")'
json.dump(old, open(sys.argv[2], "w"))
PYO
  got_new="$(gl_cases "$INFRA_DIR/scan/ignores.json" new)"
  got_old="$(gl_cases "$T/old-ignores.json" old)"
  [ "$got_new" = "token-foo.md token-second.md" ] && ok "anchored docs ignore: blank-only line skipped, both token lines reported" || bad "anchored ignore reported: '$got_new'"
  case "$got_old" in *token-second.md*|*token-foo.md*) bad "old regex unexpectedly reported: '$got_old'" ;; *) ok "old unanchored regex hides both token lines (red on old, green on new)" ;; esac
else
  echo "skip - gitleaks anchor cases (docker not reachable)"
fi

# 7. the T-37-5 report ignore (B-369) is one path, one rule and one whole line, anchored at both ends:
# the same line in another file, an added key line, or a token appended to the line is still reported.
# The line text is rebuilt from the entry's own regex, so no secret-like text lives here.
if docker info >/dev/null 2>&1; then
  d="$T/glcase-t375"; rm -rf "$d"; mkdir -p "$d/src/waves/37/reports" "$d/src/team"
  line="$(python3 - "$INFRA_DIR/scan/ignores.json" <<'PYL'
import json, re, sys
e = [x for x in json.load(open(sys.argv[1]))["ignores"] if x["id"] == "docs-ident-list-t37-5-report"][0]
print(re.sub(r"\\(.)", lambda m: " " if m.group(1) == "s" else m.group(1), e["line_regex"][4:-4]))
PYL
)"
  tk="Qx7pL2mVn9Rt4KsB8wZc3HjD5fYa6Ue1Ng0Ti"
  r="$d/src/waves/37/reports"
  # the extra cases live in the ignored file itself (the exact path), so only the line regex can reject them
  printf 'a\nb\nc\n%s\napi_key = "%s"\n%s api_key = "%s"\n' "$line" "$tk" "$line" "$tk" >"$r/T-37-5.md"
  printf 'a\nb\nc\n%s\n' "$line" >"$r/T-37-6.md"
  printf 'a\nb\nc\n%s\n' "$line" >"$d/src/team/T-37-5.md"
  printf '{"ignores":[]}' >"$d/none.json"
  t375() { # ignores-file label: generic-api-key hits as file:line
    python3 "$INFRA_DIR/scan/ignores.py" gitleaks "$1" invai-docs >"$d/$2.toml"
    docker run --rm -v "$d/src:/src:ro" -v "$d:/out" "$(sed -n 's/^GITLEAKS_IMAGE=//p' "$INFRA_DIR/scan/tools.env")" dir /src -c "/out/$2.toml" --redact --no-banner -f json -r "/out/$2.json" --exit-code 0 >/dev/null 2>&1
    python3 - "$d/$2.json" <<'PYE'
import json, sys
print(" ".join(sorted(r["File"].replace("/src/", "", 1) + ":" + str(r["StartLine"]) for r in json.load(open(sys.argv[1])) if r["RuleID"] == "generic-api-key")))
PYE
  }
  without="$(t375 "$d/none.json" none)"; with="$(t375 "$INFRA_DIR/scan/ignores.json" real)"
  case " $without " in *" waves/37/reports/T-37-5.md:4 "*) ok "T-37-5 line is flagged without the ignore (red before)" ;; *) bad "line not flagged without the ignore: '$without'" ;; esac
  case " $with " in *" waves/37/reports/T-37-5.md:4 "*) bad "T-37-5 line still flagged with the ignore: '$with'" ;; *) ok "T-37-5 line is skipped with the ignore" ;; esac
  case " $with " in *" waves/37/reports/T-37-5.md:5 "*) ok "an added key line in the ignored file itself is reported" ;; *) bad "added key line hidden: '$with'" ;; esac
  case " $with " in *" waves/37/reports/T-37-5.md:6 "*) ok "a token appended to the ignored line, same file, is reported (anchored at the end)" ;; *) bad "appended token hidden: '$with'" ;; esac
  case " $with " in *" waves/37/reports/T-37-6.md:4 "*) ok "the same line in another file of that folder is reported (path-scoped)" ;; *) bad "same line in a sibling file hidden: '$with'" ;; esac
  case " $with " in *" team/T-37-5.md:4 "*) ok "the same line in another folder is reported (path-scoped)" ;; *) bad "same line in another folder hidden: '$with'" ;; esac
else
  echo "skip - T-37-5 ignore cases (docker not reachable)"
fi

# 8. the T-38-4 round 1 report ignore is pinned to one commit: the same line at the same path in any other
# commit, or in the working tree, is still reported. Runs on a scratch repo; the entry's commit is swapped for
# the scratch commit A (the real sha only exists in invai-docs, where `scripts/scan.sh secrets` proves it).
if docker info >/dev/null 2>&1; then
  d="$T/glcase-t384"; rm -rf "$d"; mkdir -p "$d/repo/waves/38/reports"; g="git -C $d/repo -c user.name=t -c user.email=t@example.test -c commit.gpgsign=false"
  line="$(python3 - "$INFRA_DIR/scan/ignores.json" <<'PYL'
import json, re, sys
e = [x for x in json.load(open(sys.argv[1]))["ignores"] if x["id"] == "docs-ident-list-t38-4-report-f3a0903"][0]
print(re.sub(r"\\(.)", lambda m: " " if m.group(1) == "s" else m.group(1), e["line_regex"][4:-4]))
PYL
)"
  f="$d/repo/waves/38/reports/T-38-4.md"
  git -C "$d/repo" init -q; printf 'a\nb\nc\n%s\n' "$line" >"$f"; $g add . && $g commit -qm A
  shaA="$(git -C "$d/repo" rev-parse HEAD)"; $g rm -q waves/38/reports/T-38-4.md && $g commit -qm B
  mkdir -p "$d/repo/waves/38/reports"; printf 'a\nb\nc\n%s\n' "$line" >"$f"; $g add . && $g commit -qm C; shaC="$(git -C "$d/repo" rev-parse HEAD)"
  python3 - "$INFRA_DIR/scan/ignores.json" "$d/pinned.json" "$shaA" <<'PYP'
import json, sys
d = json.load(open(sys.argv[1])); e = [x for x in d["ignores"] if x["id"] == "docs-ident-list-t38-4-report-f3a0903"][0]
e["commits"] = [sys.argv[3]]; json.dump({"ignores": [e]}, open(sys.argv[2], "w"))
PYP
  printf '{"ignores":[]}' >"$d/none.json"
  t384() { # ignores-file label mode: generic-api-key hits as commit-or-tree:line
    python3 "$INFRA_DIR/scan/ignores.py" gitleaks "$1" invai-docs >"$d/$2.toml"
    docker run --rm -v "$d/repo:/repo:ro" -v "$d:/out" "$(sed -n 's/^GITLEAKS_IMAGE=//p' "$INFRA_DIR/scan/tools.env")" "$3" /repo -c "/out/$2.toml" --redact --no-banner -f json -r "/out/$2.json" --exit-code 0 >/dev/null 2>&1
    python3 - "$d/$2.json" <<'PYE'
import json, sys
print(" ".join(sorted((r.get("Commit") or "tree")[:7] + ":" + str(r["StartLine"]) for r in json.load(open(sys.argv[1])) if r["RuleID"] == "generic-api-key")))
PYE
  }
  a="${shaA:0:7}"; c="${shaC:0:7}"
  h0="$(t384 "$d/none.json" n git)"; h1="$(t384 "$d/pinned.json" p git)"; w1="$(t384 "$d/pinned.json" w dir)"
  case " $h0 " in *" $a:4 "*) fa=1 ;; *) fa=0 ;; esac; case " $h0 " in *" $c:4 "*) [ "$fa" = 1 ] && fc=1 || fc=0 ;; *) fc=0 ;; esac
  case "$fc" in 1) ok "T-38-4 line is flagged in both commits without the ignore (red before)" ;; *) bad "line not flagged in both commits without the ignore: '$h0'" ;; esac
  case " $h1 " in *" $a:4 "*) bad "the pinned commit is still flagged: '$h1'" ;; *) ok "T-38-4 line is skipped in the pinned commit" ;; esac
  case " $h1 " in *" $c:4 "*) ok "the same line at the same path in a later commit is reported" ;; *) bad "later commit hidden: '$h1'" ;; esac
  case " $w1 " in *" tree:4 "*) ok "the same line in the working tree is reported" ;; *) bad "working tree hidden: '$w1'" ;; esac
else
  echo "skip - T-38-4 ignore cases (docker not reachable)"
fi

echo "$pass passed, $failn failed"
[ "$failn" = "0" ]
