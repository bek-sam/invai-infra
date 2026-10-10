#!/usr/bin/env bash
# Mechanical checks for the deploy workflow, package scripts and IAM policy files (T-34-1, AC 1-5).
# Run: `pnpm deploy:test`. Reads files only; never calls AWS, GitHub or sst.
# INFRA_DIR overrides the infra checkout under test (used to prove the suite is red on an old commit).
# bash 3.2 compatible; needs python3 (standard library only).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
export INFRA_DIR
WF="$INFRA_DIR/.github/workflows/deploy.yml"
PKG="$INFRA_DIR/package.json"
IAM="$INFRA_DIR/infra/iam"
fail=0
n=0

check() { # check <name> <exit code of the test>
  n=$((n + 1))
  if [ "$2" -eq 0 ]; then echo "ok $n - $1"; else echo "not ok $n - $1"; fail=1; fi
}
wf_has() { grep -qE -- "$1" "$WF" 2>/dev/null; }

# AC1 stage choices and triggers
wf_has '^        options: \[demo, staging, production\]$'; check "AC1 dispatch offers demo, staging, production" $?
wf_has '^    tags: \["v\*"\]$'; check "AC1 a v* tag push still triggers" $?
wf_has "^    environment: \\$\\{\\{ github.event_name == 'push' && 'production' \\|\\| inputs.stage \\}\\}$"; check "AC1 job environment is the stage (tag selects production)" $?

# AC2 variables, guard, no placeholder
wf_has 'vars\.INVAI_DOMAIN'; check "AC2 reads INVAI_DOMAIN from vars" $?
wf_has 'role-to-assume: \$\{\{ vars\.AWS_DEPLOY_ROLE_ARN \}\}'; check "AC2 role ARN comes from vars" $?
! wf_has '123456789012'; check "AC2 placeholder account id is gone" $?
python3 - "$WF" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
steps = t.split("\n      - ")
guard = next((s for s in steps if "INVAI_DOMAIN" in s and "::error::" in s), None)
assert guard, "no guard step"
assert "AWS_DEPLOY_ROLE_ARN" in guard and "-z" in guard, "guard misses the role variable"
assert t.index(guard) < t.index("configure-aws-credentials"), "guard must run before the AWS step"
PY
check "AC2 a guard step names both variables and runs before AWS" $?
python3 - "$WF" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"\n    env:\n((?:      .*\n)+)", t)
assert m, "no job-level env"
e = m.group(1)
for k in ("INVAI_DOMAIN", "INVAI_OTEL_ENDPOINT", "STAGE"):
    assert re.search(r"^      %s:" % k, e, re.M), k + " missing in job env"
assert re.search(r"role-duration-seconds: 7200", t), "role-duration-seconds 7200 missing"
assert re.search(r"timeout-minutes: 120", t), "timeout-minutes 120 missing"
PY
check "AC2 job env has INVAI_DOMAIN, INVAI_OTEL_ENDPOINT, STAGE; 7200 s session; 120 min timeout" $?

# AC3 package scripts: Migrate target, then release task, then full deploy
python3 - "$PKG" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["scripts"]
for pk, st, rel in (("deploy:demo", "demo", "demo"), ("deploy:staging", "staging", "staging"), ("deploy:prod", "production", "prod")):
    want = "sst deploy --stage %s --target Migrate && pnpm release:migrate:%s && sst deploy --stage %s" % (st, rel, st)
    assert s.get(pk) == want, "%s is %r" % (pk, s.get(pk))
    r = s.get("release:migrate:" + rel)
    assert r == "sst shell --stage %s -- node infra/run-migrate.ts" % st, "release:migrate:%s is %r" % (rel, r)
assert s.get("deploy:test") == "bash scripts/deploy/deploy-config.test.sh", "deploy:test missing"
PY
check "AC3 deploy:demo|staging|prod run Migrate, release task, full deploy in that order" $?
python3 - "$WF" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
for k, v in (("demo", "deploy:demo"), ("staging", "deploy:staging"), ("production", "deploy:prod")):
    assert re.search(r"^\s+%s\) pnpm %s ;;$" % (k, re.escape(v)), t, re.M), "workflow does not run pnpm " + v
code = "\n".join(l for l in t.split("\n") if not l.lstrip().startswith("#"))
assert not re.search(r"\bsst (deploy|shell)\b", code), "workflow calls sst directly"
PY
check "AC3 workflow runs the same package scripts a laptop runs, not sst directly" $?

# AC4 no expression inside run:, pinned actions, concurrency, permissions
python3 - "$WF" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
bad = []
i = 0
while i < len(lines):
    m = re.match(r"^(\s*)(?:- )?run:\s*(.*)$", lines[i])
    if m:
        ind = len(m.group(1)); body = [m.group(2)]
        if m.group(2) in ("|", ">", "|-", ">-"):
            body = []
            j = i + 1
            while j < len(lines) and (lines[j].strip() == "" or len(lines[j]) - len(lines[j].lstrip()) > ind):
                body.append(lines[j]); j += 1
            i = j - 1
        if any("${{" in b for b in body):
            bad.append(body)
    i += 1
assert not bad, "expression inside run: %r" % bad
PY
check "AC4 no \${{ }} expression inside any run: script" $?
python3 - "$WF" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
for m in re.finditer(r"uses:\s*(\S+)", t):
    assert re.search(r"@[0-9a-f]{40}$", m.group(1)), "unpinned " + m.group(1)
PY
check "AC4 every action is pinned by a 40-character SHA" $?
python3 - "$WF" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"^concurrency:\n  group: (.*)\n  cancel-in-progress: false$", t, re.M)
assert m and "inputs.stage" in m.group(1) and "production" in m.group(1), "concurrency group per stage with cancel-in-progress false missing"
assert re.search(r"^permissions:\n  id-token: write\n  contents: read\n\n?(?=\S)", t, re.M), "top-level permissions must be exactly id-token write, contents read"
PY
check "AC4 concurrency is one group per stage, never cancelled; permissions least" $?

# AC5 trust and SMTP policy files
python3 - "$IAM" <<'PY'
import json, sys, os, re
d = sys.argv[1]
AUD = "token.actions.githubusercontent.com:aud"; SUB = "token.actions.githubusercontent.com:sub"
def load(n):
    return json.load(open(os.path.join(d, n)))
for name, subs in (("deploy-trust-nonprod.json", ["repo:bek-sam/invai-infra:environment:demo", "repo:bek-sam/invai-infra:environment:staging"]),
                   ("deploy-trust-production.json", ["repo:bek-sam/invai-infra:environment:production"])):
    doc = load(name)
    st = doc["Statement"]
    assert len(st) == 1, name + ": one statement expected"
    st = st[0]
    assert st["Effect"] == "Allow" and st["Action"] == "sts:AssumeRoleWithWebIdentity", name + ": action"
    assert list(st["Condition"].keys()) == ["StringEquals"], name + ": only StringEquals"
    c = st["Condition"]["StringEquals"]
    assert set(c.keys()) == {AUD, SUB}, name + ": condition keys"
    assert c[AUD] == "sts.amazonaws.com", name + ": aud"
    got = c[SUB] if isinstance(c[SUB], list) else [c[SUB]]
    assert sorted(got) == sorted(subs), name + ": subjects %r" % got
    raw = open(os.path.join(d, name)).read()
    assert "*" not in raw and "StringLike" not in raw and ":ref:" not in raw, name + ": wildcard or ref subject"
    assert set(re.findall(r"<[A-Z_]+>", raw)) <= {"<ACCOUNT_ID>"}, name + ": placeholders"
PY
check "AC5 trust files: exact environment subjects, StringEquals on aud and sub, no wildcard or ref" $?
python3 - "$IAM" <<'PY'
import json, sys, os, re
p = os.path.join(sys.argv[1], "smtp-send.json")
raw = open(p).read(); doc = json.loads(raw)
st = doc["Statement"]
assert len(st) == 1 and st[0]["Effect"] == "Allow", "one Allow statement"
a = st[0]["Action"]
assert (a if isinstance(a, list) else [a]) == ["ses:SendRawEmail"], "actions %r" % a
r = st[0]["Resource"]
assert sorted(r) == sorted(["arn:aws:ses:<REGION>:<ACCOUNT_ID>:identity/<MAIL_DOMAIN>",
                            "arn:aws:ses:<REGION>:<ACCOUNT_ID>:configuration-set/<CONFIG_SET_NAME>"]), "resources %r" % r
assert set(re.findall(r"<[A-Z_]+>", raw)) <= {"<ACCOUNT_ID>", "<REGION>", "<MAIL_DOMAIN>", "<CONFIG_SET_NAME>"}, "placeholders"
assert "*" not in raw, "wildcard"
PY
check "AC5 smtp-send.json allows only ses:SendRawEmail on the identity and its configuration set" $?
[ -f "$IAM/README.md" ]; check "AC5 infra/iam/README.md exists" $?

# T-34-4 tracing in deployed stages (AC 1, 2, 4). BACKEND_DIR overrides the backend checkout (Dockerfile).
BACKEND_DIR="${BACKEND_DIR:-$(cd "$INFRA_DIR/../invai-backend" && pwd)}"
export BACKEND_DIR
SST="$INFRA_DIR/sst.config.ts"
OTEL_TS="$INFRA_DIR/scripts/deploy/otel-endpoint.ts"
OTEL_CASE="$(mktemp -t otel-case.XXXXXX).mjs"
trap 'rm -f "$OTEL_CASE" "${OTEL_CASE%.mjs}"' EXIT
cat > "$OTEL_CASE" <<JS
const { otelEndpoint, otelEnv } = await import("file://$OTEL_TS");
const refused = (v) => { try { otelEndpoint(v); return false; } catch (e) { return /INVAI_OTEL_ENDPOINT/.test(e.message); } };
const eq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) { console.error(m, JSON.stringify(a)); process.exit(1); } };
for (const v of [undefined, "", "   "]) {
  eq(otelEndpoint(v), null, "unset/blank must be null");
  for (const s of ["invai-api", "invai-worker", "invai-imaging"]) eq(otelEnv(v, s, "staging"), {}, "unset must add no env for " + s);
}
for (const v of ["https://collector.example.com", "https://collector.example.com:4318/otlp", "http://localhost:4318", "http://127.0.0.1:4318"])
  eq(otelEndpoint(v), v, "accepted " + v);
for (const v of ["http://collector.example.com:4318", "http://10.0.0.5:4318", "http://127.0.0.1", "http://127.0.0.1.evil.example:4318", "http://localhost.evil.example:4318",
  "http://[::1]:4318", "http://0.0.0.0:4318", "ftp://collector.example.com", "collector.example.com", "https://user:pw@collector.example.com", "https://c.example.com/?k=v", "javascript:1"])
  if (!refused(v)) { console.error("not refused:", v); process.exit(1); }
eq(otelEnv("https://c.example.com", "invai-imaging", "demo"),
  { OTEL_EXPORTER_OTLP_ENDPOINT: "https://c.example.com", OTEL_SERVICE_NAME: "invai-imaging", OTEL_RESOURCE_ATTRIBUTES: "deployment.environment=demo" }, "env shape");
const imaging = otelEnv("https://c.example.com", "invai-imaging", "staging");
eq(imaging.OTEL_RESOURCE_ATTRIBUTES, "deployment.environment=staging", "imaging resource attributes");
JS
[ -f "$OTEL_TS" ] && node --experimental-strip-types --no-warnings "$OTEL_CASE" >/dev/null 2>&1
check "T34-4 AC4 helper: unset adds no OTEL env; imaging gets deployment.environment; http only on loopback with a port; https ok; others refused" $?
python3 - "$SST" "$BACKEND_DIR/Dockerfile" <<'PY'
import re, sys
raw = open(sys.argv[1]).read()
code = "\n".join(l for l in raw.split("\n") if not l.lstrip().startswith("//"))
docker = open(sys.argv[2]).read()
def block(name):
    m = re.search(r'new sst\.aws\.(?:Service|Task)\("%s",.*?\n    \}\);' % name, code, re.S)
    assert m, name + " block missing"
    return m.group(0)
def cmd(name):
    m = re.search(r'\n      command: (\[[^\]]*\]),', block(name), re.S)
    assert m, name + " command missing"
    return m.group(1)
api = '["node", "--import", "./dist/lib/telemetry.js", "dist/api/server.js"]'
wrk = '["node", "--import", "./dist/lib/telemetry.js", "dist/worker/index.js"]'
assert cmd("Api") == api, "Api command is " + cmd("Api")
assert cmd("Worker") == wrk, "Worker command is " + cmd("Worker")
assert re.search(r'^CMD ' + re.escape(api) + r'$', docker, re.M), "Dockerfile CMD differs from the Api command"
assert "node dist/db/bootstrap-cli.js && node dist/db/migrate-cli.js && node dist/db/reference-seed-cli.js" in block("Migrate"), "release task command changed"
assert "--import" not in block("Migrate"), "release task must not load telemetry"
PY
check "T34-4 AC1 Api and Worker commands and the Dockerfile CMD use --import ./dist/lib/telemetry.js; release task unchanged" $?
python3 - "$SST" <<'PY'
import re, sys
raw = open(sys.argv[1]).read()
code = "\n".join(l for l in raw.split("\n") if not l.lstrip().startswith("//"))
def block(name):
    m = re.search(r'new sst\.aws\.(?:Service|Task)\("%s",.*?\n    \}\);' % name, code, re.S)
    assert m, name + " block missing"
    return m.group(0)
for svc, name in (("Api", "invai-api"), ("Worker", "invai-worker"), ("Imaging", "invai-imaging")):
    assert ('otelEnv(process.env.INVAI_OTEL_ENDPOINT, "%s", stage)' % name) in block(svc), svc + " lacks otelEnv"
assert "otel" not in block("Migrate").lower(), "release task must get no OTEL env"
be = re.search(r"const backendEnvironment = \{.*?\n    \};", code, re.S).group(0)
assert "OTEL" not in be, "shared backendEnvironment must not carry OTEL (Migrate uses it)"
assert not re.search(r"(?<![A-Z_])OTEL_", code), "OTEL_ variable named outside the helper"
assert "otelEndpoint(process.env.INVAI_OTEL_ENDPOINT)" in code, "stage never validates the endpoint at plan time"
PY
check "T34-4 AC2 only Api, Worker, Imaging get OTEL env, via the helper; endpoint validated at plan time" $?

# T-35-2 (B-352) no persisted git credential; the stage allow lists are run for real.
python3 - "$WF" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
steps = re.split(r"\n      - ", t)
co = [s for s in steps if s.startswith("uses: actions/checkout@")]
assert len(co) == 7, "expected 7 checkout steps, found %d" % len(co)
for s in co:
    assert re.search(r"^          persist-credentials: false$", s, re.M), "checkout without persist-credentials: false: " + s.split("\n")[0]
PY
check "T35-2 AC1 all 7 actions/checkout steps set persist-credentials: false" $?
SCR="$(mktemp -d -t deploy-stage.XXXXXX)"
trap 'rm -rf "$SCR"; rm -f "$OTEL_CASE" "${OTEL_CASE%.mjs}"' EXIT
python3 - "$WF" "$SCR" <<'PY'
import re, sys, os
t = open(sys.argv[1]).read().split("\n")
out = sys.argv[2]
blocks = []
for i, l in enumerate(t):
    m = re.match(r"^(\s*)(?:- )?run:\s*\|\s*$", l)
    if m:
        ind = len(m.group(1)); body = []
        j = i + 1
        while j < len(t) and (t[j].strip() == "" or len(t[j]) - len(t[j].lstrip()) > ind):
            body.append(t[j]); j += 1
        blocks.append("\n".join(body))
guard = [b for b in blocks if "Unknown stage '$STAGE'. Use" in b]
deploy = [b for b in blocks if "pnpm deploy:demo" in b]
assert len(guard) == 1 and len(deploy) == 1, "allow-list run blocks not found (%d, %d)" % (len(guard), len(deploy))
open(os.path.join(out, "guard.sh"), "w").write(guard[0] + "\n")
open(os.path.join(out, "deploy.sh"), "w").write(deploy[0] + "\n")
PY
check "T35-2 AC2 both stage allow-list run blocks found in the workflow" $?
mkdir -p "$SCR/bin"
printf '#!/bin/sh\necho "$@" >> "$PNPM_LOG"\n' > "$SCR/bin/pnpm"; chmod +x "$SCR/bin/pnpm"
stage_run() { # stage_run <script> <stage>; prints stdout+stderr, returns the script's exit code
  PNPM_LOG="$SCR/pnpm.log" PATH="$SCR/bin:$PATH" STAGE="$2" INVAI_DOMAIN="x.example.com" AWS_DEPLOY_ROLE_ARN="set" \
    bash "$SCR/$1" 2>&1
}
ok=0
for s in demo staging production; do
  stage_run guard.sh "$s" >/dev/null || ok=1
done
check "T35-2 AC2 guard step passes demo, staging and production" $ok
ok=0
for s in prod Production staging2 "demo " ""; do
  out="$(stage_run guard.sh "$s")"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "Unknown stage"; then :; else ok=1; fi
done
check "T35-2 AC2 guard step refuses prod, Production, staging2, 'demo ' and empty with Unknown stage" $ok
ok=0
for pair in "demo:deploy:demo" "staging:deploy:staging" "production:deploy:prod"; do
  s="${pair%%:*}"; want="${pair#*:}"; : > "$SCR/pnpm.log"
  stage_run deploy.sh "$s" >/dev/null || ok=1
  [ "$(cat "$SCR/pnpm.log")" = "$want" ] || ok=1
done
check "T35-2 AC2 deploy step runs exactly deploy:demo, deploy:staging, deploy:prod for the three stages" $ok
ok=0
for s in prod Production ""; do
  : > "$SCR/pnpm.log"
  out="$(stage_run deploy.sh "$s")"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "Unknown stage" && [ ! -s "$SCR/pnpm.log" ]; then :; else ok=1; fi
done
check "T35-2 AC2 deploy step refuses prod, Production and empty and never calls pnpm" $ok

echo "# $n checks"
exit $fail
