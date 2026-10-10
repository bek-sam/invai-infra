#!/usr/bin/env bash
# One local command that scans the whole workspace (T-31-4). `pnpm scan` from invai-infra.
#
#   scan.sh [all]      ignores + secrets + deps + images + workflows + hardening
#   scan.sh secrets    gitleaks: full git history and the working tree of the 7 code repos + invai-docs
#   scan.sh deps       trivy on every lockfile (pnpm-lock.yaml x6, imaging uv.lock), dev deps included
#   scan.sh images     trivy on invai-full-{backend,imaging,web,floor}:local (build them: full.sh build)
#   scan.sh workflows  actionlint, every `uses:` pinned by 40-hex SHA, top-level `permissions:`
#   scan.sh hardening  S-62 checks: 127.0.0.1 ports, env -i seed, BuildKit ignore-file canary,
#                      Dockerfile pins (digest, USER, corepack hash), tool digests match CI
#   scan.sh ignores    scan/ignores.json: reason, owner and an unexpired date on every entry
#   scan.sh sync       rewrite each repo's .github/trivyignore.yaml from scan/ignores.json (CI uses it)
#
# Exit 0 only if nothing is at or above the threshold: any secret, or a HIGH/CRITICAL vulnerability
# that has a fixed version. Ignores live in scan/ignores.json only; each has a reason and an expiry,
# and an expired ignore fails the scan. Tools run as containers pinned by digest (scan/tools.env);
# nothing is uploaded anywhere. Results go to $SCAN_OUT (default $TMPDIR/invai-scan, outside every repo) and
# only counts and a findings table are printed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WS="${SCAN_WORKSPACE:-$(cd "$INFRA_DIR/.." && pwd)}"
OUT="${SCAN_OUT:-${TMPDIR:-/tmp}/invai-scan}"
CACHE="${SCAN_CACHE:-$HOME/.cache/invai-scan}"
IGN="${SCAN_IGNORES:-$INFRA_DIR/scan/ignores.json}"
PY="python3 $INFRA_DIR/scan/ignores.py"
# shellcheck source=../scan/tools.env
. "$INFRA_DIR/scan/tools.env"

CODE_REPOS="invai-contracts invai-ui invai-backend invai-web invai-floor invai-imaging invai-infra"
SECRET_REPOS="$CODE_REPOS invai-docs"
IMAGES="backend imaging web floor"
FAILED=""

log() { printf '\n==> %s\n' "$1"; }
fail() { FAILED="$FAILED $1"; }
need_docker() {
  docker info >/dev/null 2>&1 || { echo "docker daemon is not reachable. Run 'orb stop && orb start' and retry." >&2; exit 2; }
}

mkdir -p "$OUT" "$CACHE/trivy"
rm -rf "$OUT/tree"
mkdir -p "$OUT/tree"

# Tracked plus untracked-but-not-ignored files: what a commit could contain. Ignored files (a host
# .env with real keys, seed-output.json, node_modules) never enter a scanner container.
tree_export() {
  local repo="$1" dest="$OUT/tree/$1"
  mkdir -p "$dest"
  # pipefail is on: a git or tar error fails the export, and so does an empty result (S-63).
  git -C "$WS/$repo" ls-files -co --exclude-standard -z | tar -C "$WS/$repo" --null -T - -cf - 2>"$OUT/tree-$repo.err" | tar -xf - -C "$dest" 2>>"$OUT/tree-$repo.err" \
    || { echo "   could not export $repo (see $OUT/tree-$repo.err)"; return 1; }
  [ -n "$(find "$dest" -type f -print -quit)" ] || { echo "   exported tree of $repo is empty: nothing to scan"; return 1; }
}

# ---- ignores ------------------------------------------------------------------------------------
step_ignores() {
  log "ignores: reason, owner and expiry on every entry; CI copies in sync"
  $PY check "$IGN" || fail ignores
  $PY check-ci "$IGN" "$WS" || fail ignores-ci-drift
}

step_sync() { $PY sync-ci "$IGN" "$WS"; }

# ---- secrets ------------------------------------------------------------------------------------
step_secrets() {
  need_docker
  log "secrets: gitleaks (history and working tree) on: $SECRET_REPOS"
  local repo n_git n_tree
  for repo in $SECRET_REPOS; do
    $PY gitleaks "$IGN" "$repo" >"$OUT/gl-$repo.toml"
    docker run --rm -v "$WS/$repo:/repo:ro" -v "$OUT:/out" "$GITLEAKS_IMAGE" git /repo \
      -c "/out/gl-$repo.toml" --redact --no-banner -f json -r "/out/gl-$repo-git.json" --exit-code 0 >/dev/null 2>"$OUT/gl-$repo-git.err" \
      || { echo "   gitleaks failed on $repo history (see $OUT/gl-$repo-git.err)"; fail "secrets-$repo-run"; continue; }
    tree_export "$repo" || { fail "secrets-$repo-export"; continue; }
    docker run --rm -v "$OUT/tree/$repo:/src:ro" -v "$OUT:/out" "$GITLEAKS_IMAGE" dir /src \
      -c "/out/gl-$repo.toml" --redact --no-banner -f json -r "/out/gl-$repo-tree.json" --exit-code 0 >/dev/null 2>"$OUT/gl-$repo-tree.err" \
      || { echo "   gitleaks failed on $repo tree (see $OUT/gl-$repo-tree.err)"; fail "secrets-$repo-run"; continue; }
    n_git="$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$OUT/gl-$repo-git.json")"
    n_tree="$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$OUT/gl-$repo-tree.json")"
    printf '   %-16s history=%s tree=%s\n' "$repo" "$n_git" "$n_tree"
    [ "$n_git" = "0" ] && [ "$n_tree" = "0" ] || fail "secrets-$repo"
  done
}

# ---- dependencies -------------------------------------------------------------------------------
trivy_json_table() { # label json...: print HIGH/CRITICAL rows
  python3 - "$@" <<'PYEOF'
import json, sys
label = sys.argv[1]
for p in sys.argv[2:]:
    for r in json.load(open(p)).get("Results") or []:
        for v in r.get("Vulnerabilities") or []:
            print("   %-9s %-8s %-18s %-26s %-12s -> %s" % (label, v["Severity"], v["VulnerabilityID"], v["PkgName"], v["InstalledVersion"], v.get("FixedVersion", "?")[:40]))
        for s in r.get("Secrets") or []:
            print("   %-9s SECRET   %s in %s" % (label, s.get("RuleID"), s.get("Target")))
PYEOF
}

trivy_count() { python3 "$INFRA_DIR/scan/ignores.py" summary "$1" | sed -E 's/^[^ ]+ //'; }

step_deps() {
  need_docker
  log "dependencies: trivy on lockfiles, HIGH/CRITICAL with a fix, dev deps included"
  local repo lock
  for repo in $CODE_REPOS; do
    lock="pnpm-lock.yaml"; [ -f "$WS/$repo/uv.lock" ] && lock="uv.lock"
    tree_export "$repo" || { fail "deps-$repo-export"; continue; }
    [ -f "$OUT/tree/$repo/$lock" ] || { echo "   $repo: $lock is missing from the exported tree"; fail "deps-$repo-lockfile"; continue; }
    $PY trivy "$IGN" "$repo" >"$OUT/ti-$repo.yaml"
    docker run --rm -v "$CACHE/trivy:/root/.cache" -v "$OUT/tree/$repo:/src:ro" -v "$OUT:/out" "$TRIVY_IMAGE" fs /src \
      --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --include-dev-deps --ignorefile /out/ti-$repo.yaml \
      -f json -o "/out/tv-$repo.json" --quiet >/dev/null 2>"$OUT/tv-$repo.err" \
      || { echo "   trivy failed on $repo (see $OUT/tv-$repo.err)"; fail "deps-$repo-run"; continue; }
    $PY expect "$OUT/tv-$repo.json" file "$lock" || { fail "deps-$repo-empty"; continue; }
    printf '   %-16s %-15s %s\n' "$repo" "$lock" "$(trivy_count "$OUT/tv-$repo.json")"
    trivy_json_table "$repo" "$OUT/tv-$repo.json"
    $PY summary "$OUT/tv-$repo.json" >/dev/null || fail "deps-$repo"
  done
}

# ---- images -------------------------------------------------------------------------------------
step_images() {
  need_docker
  log "images: trivy (vulnerabilities and secrets) on invai-full-*:local"
  local n
  for n in $IMAGES; do
    if ! docker image inspect "invai-full-${n}:local" >/dev/null 2>&1; then
      echo "   invai-full-${n}:local is missing. Build the images first: bash scripts/full.sh build"
      fail "images-$n-missing"
      continue
    fi
    $PY trivy "$IGN" "image:$n" >"$OUT/ti-image-$n.yaml"
    docker save "invai-full-${n}:local" -o "$OUT/img-$n.tar"
    docker run --rm -v "$CACHE/trivy:/root/.cache" -v "$OUT:/out" "$TRIVY_IMAGE" image --input "/out/img-$n.tar" \
      --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed --ignorefile "/out/ti-image-$n.yaml" \
      -f json -o "/out/ti-$n.json" --quiet >/dev/null 2>"$OUT/ti-$n.err" \
      || { echo "   trivy failed on image $n (see $OUT/ti-$n.err)"; fail "images-$n-run"; rm -f "$OUT/img-$n.tar"; continue; }
    rm -f "$OUT/img-$n.tar"
    $PY expect "$OUT/ti-$n.json" image || { fail "images-$n-empty"; continue; }
    printf '   %-16s %s\n' "image:$n" "$(trivy_count "$OUT/ti-$n.json")"
    trivy_json_table "image:$n" "$OUT/ti-$n.json"
    $PY summary "$OUT/ti-$n.json" >/dev/null || fail "images-$n"
  done
}

# ---- workflows ----------------------------------------------------------------------------------
step_workflows() {
  need_docker
  log "workflows: actionlint, SHA pins, top-level permissions"
  local repo rc
  for repo in $CODE_REPOS; do
    [ -d "$WS/$repo/.github/workflows" ] || continue
    docker run --rm -v "$WS/$repo:/repo:ro" -w /repo "$ACTIONLINT_IMAGE" -color >"$OUT/al-$repo.txt" 2>&1
    rc=$?
    printf '   %-16s actionlint rc=%s (%s lines)\n' "$repo" "$rc" "$(wc -l <"$OUT/al-$repo.txt" | tr -d ' ')"
    if [ "$rc" != "0" ]; then head -n 8 "$OUT/al-$repo.txt" | sed 's/^/      /'; fail "actionlint-$repo"; fi
  done
  # shellcheck disable=SC2086
  $PY pins "$WS" $CODE_REPOS || fail workflow-pins
}

# ---- hardening (S-62) ---------------------------------------------------------------------------
canary() { # repo: BuildKit must honour <Dockerfile>.dockerignore, so planted secrets stay out
  local repo="$1" d rc
  d="$(mktemp -d)"
  mkdir -p "$d/$repo/src" "$d/$repo/.git" "$d/$repo/e2e" "$d/$repo/node_modules/x"
  for f in src/.env src/.env.local .env src/seed-output.json src/a.test.ts e2e/a.ts .git/config node_modules/x/i.js; do
    echo "CANARY-NOT-A-SECRET" >"$d/$repo/$f"
  done
  echo "ok" >"$d/$repo/src/ok.ts"
  cp "$WS/$repo/Dockerfile.dockerignore" "$d/Probe.dockerignore"
  cat >"$d/Probe" <<EOF
FROM $PROBE_IMAGE
COPY . /ctx
RUN test -f /ctx/$repo/src/ok.ts || { echo "probe: the allowed file is missing, the ignore file is too strict"; exit 2; }; \\
    leaked="\$(find /ctx \\( -name '.env*' -o -name 'seed-output.json' -o -name '*.test.ts' -o -path '*/e2e/*' -o -path '*/.git/*' -o -path '*/node_modules/*' \\) | head -n 5)"; \\
    [ -z "\$leaked" ] || { echo "LEAKED into the build context: \$leaked"; exit 1; }
EOF
  DOCKER_BUILDKIT=1 docker build --no-cache -q -f "$d/Probe" "$d" >"$OUT/canary-$repo.log" 2>&1
  rc=$?
  rm -rf "$d"
  return $rc
}

step_hardening() {
  need_docker
  log "hardening (S-62, B-315)"
  local repo n f bad

  # a) full-profile ports bind to loopback only
  bad="$(cd "$INFRA_DIR/local" && docker compose --profile full config --format json 2>/dev/null | python3 -c '
import json, sys
bad = []
for name, svc in json.load(sys.stdin)["services"].items():
    if "full" not in (svc.get("profiles") or []):
        continue
    for p in svc.get("ports") or []:
        if p.get("host_ip") != "127.0.0.1":
            bad.append("%s:%s" % (name, p.get("published")))
print(" ".join(bad))')"
  if [ -z "$bad" ]; then echo "   ports: every full-profile port binds 127.0.0.1"; else echo "   FAIL ports not on 127.0.0.1: $bad"; fail ports; fi

  # b) the seed runs under env -i with the explicit list
  if grep -q 'env -i' "$SCRIPT_DIR/full.sh" && grep -q 'INVAI_SKIP_DOTENV=1' "$SCRIPT_DIR/full.sh" && ! grep -q 'seed_env' "$SCRIPT_DIR/full.sh"; then
    echo "   seed: full.sh runs it under env -i with INVAI_SKIP_DOTENV=1"
  else
    echo "   FAIL seed: full.sh must run the seed under env -i + explicit list"; fail seed-env
  fi

  # c) BuildKit-only ignore files: present, allowlist-style, and honoured by the builder (canary)
  for repo in invai-backend invai-web invai-floor; do
    f="$WS/$repo/Dockerfile.dockerignore"
    if [ ! -f "$f" ] || [ "$(grep -m1 -v '^#' "$f")" != "*" ]; then
      echo "   FAIL $repo: Dockerfile.dockerignore missing or not an allowlist (first rule must be *)"; fail "dockerignore-$repo"; continue
    fi
    if grep -qE '^!.*\.env' "$f"; then echo "   FAIL $repo: Dockerfile.dockerignore re-allows an .env file"; fail "dockerignore-$repo"; continue; fi
    if canary "$repo"; then echo "   canary $repo: planted .env/seed-output/.git/e2e stayed out of the build context"
    else echo "   FAIL canary $repo: $(tail -n 3 "$OUT/canary-$repo.log" | tr '\n' ' ' | cut -c1-200)"; fail "canary-$repo"; fi
  done
  [ -f "$WS/invai-imaging/.dockerignore" ] && grep -q '^\.env' "$WS/invai-imaging/.dockerignore" || { echo "   FAIL imaging: .dockerignore must exclude .env*"; fail dockerignore-imaging; }

  # d) Dockerfile pins: digests, non-root, corepack hash
  for repo in invai-backend invai-imaging invai-web invai-floor; do
    f="$WS/$repo/Dockerfile"
    bad="$(awk '/^FROM /{ if ($2 !~ /@sha256:/ && !($2 in st)) print $0; for (i = 1; i <= NF; i++) if ($i == "AS") st[$(i + 1)] = 1 }
      /^COPY --from=/{ s = $2; sub("--from=", "", s); if (s ~ /[:\/]/ && s !~ /@sha256:/) print $0 }' "$f")"
    [ -z "$bad" ] || { echo "   FAIL $repo Dockerfile: image not pinned by digest: $bad"; fail "dockerfile-pin-$repo"; }
    grep -q '^USER ' "$f" || { echo "   FAIL $repo Dockerfile: no USER"; fail "dockerfile-user-$repo"; }
    if grep -q 'corepack enable' "$f"; then
      n="$(grep -c 'corepack enable' "$f")"
      [ "$(grep -c 'corepack prepare pnpm@[0-9.]*+sha512\.[0-9a-f]\{128\}' "$f")" = "$n" ] \
        || { echo "   FAIL $repo Dockerfile: every 'corepack enable' needs 'corepack prepare pnpm@x+sha512.<hex>'"; fail "dockerfile-corepack-$repo"; }
    fi
  done
  echo "   Dockerfiles: digests, USER and corepack hash checked in backend, imaging, web, floor"

  # e) scanner digests in CI match scan/tools.env
  bad=""
  for repo in $CODE_REPOS; do
    for f in "$WS/$repo"/.github/workflows/*.yml; do
      [ -f "$f" ] || continue
      for n in "$GITLEAKS_IMAGE" "$TRIVY_IMAGE" "$ACTIONLINT_IMAGE"; do
        base="${n%@*}"
        if grep -q "$base@sha256:" "$f" && ! grep -q "$n" "$f"; then bad="$bad $repo/$(basename "$f"):$base"; fi
      done
    done
  done
  if [ -z "$bad" ]; then echo "   CI: scanner digests in workflows match scan/tools.env"; else echo "   FAIL CI digests differ from scan/tools.env:$bad"; fail ci-digests; fi

  # f) local:full goes through full.sh
  if grep -q '"local:full": "bash scripts/full.sh up"' "$INFRA_DIR/package.json"; then echo "   package.json: local:full calls scripts/full.sh up"
  else echo "   FAIL package.json: local:full must call 'bash scripts/full.sh up'"; fail local-full; fi
}

# ---- main ---------------------------------------------------------------------------------------
cmd="${1:-all}"
case "$cmd" in
  all) step_ignores; step_secrets; step_deps; step_images; step_workflows; step_hardening ;;
  secrets) step_secrets ;;
  deps) step_deps ;;
  images) step_images ;;
  workflows) step_workflows ;;
  hardening) step_hardening ;;
  ignores) step_ignores ;;
  sync) step_sync ;;
  *) echo "usage: scan.sh [all|secrets|deps|images|workflows|hardening|ignores|sync]" >&2; exit 2 ;;
esac

echo
if [ -z "$FAILED" ]; then
  echo "SCAN PASSED ($cmd)"
  exit 0
fi
echo "SCAN FAILED ($cmd):$FAILED"
echo "details: $OUT"
exit 1
