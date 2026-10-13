#!/usr/bin/env bash
# Static checks (T-49-2 part A, AC1-AC3 and AC5; T-50-2 per-service lists and anchors) that the app's services cannot read, list or delete
# old object versions or change the Files bucket's versioning, lifecycle or policy, and that the
# crash alarm watches the right log lines. Reads files only; never calls AWS, MinIO or sst.
# Run: `pnpm files-iam:test`. INFRA_DIR / BACKEND_DIR override the trees under test (mutant runs).
# bash 3.2 compatible; needs python3 and node 24 (type stripping).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BACKEND_DIR="${BACKEND_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)/invai-backend}"
export INFRA_DIR BACKEND_DIR
SST="$INFRA_DIR/sst.config.ts"
MOD="$INFRA_DIR/infra/files-access.ts"
fail=0
n=0
check() { n=$((n + 1)); if [ "$2" -eq 0 ]; then echo "ok $n - $1"; else echo "not ok $n - $1"; fail=1; fi; }

DUMP="$(mktemp)"
trap 'rm -f "$DUMP"' EXIT
cat > "$DUMP.mjs" <<'JS'
const m = await import(process.argv[2]);
const B = "BUCKET", O = "OBJECTS";
console.log(JSON.stringify({
  byService: m.FILES_ALLOW_OBJECT_ACTIONS_BY_SERVICE,
  allowBucket: m.FILES_ALLOW_BUCKET_ACTIONS,
  deny: m.FILES_DENY_ACTIONS,
  statements: Object.fromEntries(["api", "worker", "imaging", "migrate"].map((s) => [s, m.filesPermissionsFor(s, B, O)])),
  doc: m.filesPolicyDocument("w50-t-50-2-x", "imaging"),
  msg: m.UNHANDLED_REJECTION_MSG,
  pattern: m.UNHANDLED_REJECTION_FILTER_PATTERN,
  alarm: m.UNHANDLED_REJECTION_ALARM,
  ns: m.metricNamespace("demo"),
  api: m.appLogGroupName("demo", "api"),
  worker: m.appLogGroupName("demo", "worker"),
}));
JS
trap 'rm -f "$DUMP" "$DUMP.mjs"' EXIT
node --experimental-strip-types --no-warnings "$DUMP.mjs" "$MOD" > "$DUMP" 2>"$DUMP.err" || { echo "not ok - cannot load $MOD"; cat "$DUMP.err"; rm -f "$DUMP.err"; exit 1; }
rm -f "$DUMP.err"
export DUMP

# (a) evaluate filesPermissionsFor for every service. Calls (T-50-2 inventory): api and worker use
# lib/s3.ts get/put/delete/multipart/list/head; imaging storage.py head bucket, get, put, multipart abort
# and never delete; migrate (run-migrate.ts / bootstrap, migrate, reference-seed CLIs) makes no S3 call.
python3 - <<'PY'
import json, os
d = json.load(open(os.environ["DUMP"]))
st = d["statements"]
want = {
  "api": {"s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"},
  "worker": {"s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"},
  "imaging": {"s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"},
  "migrate": set(),
}
assert set(st) == set(want), list(st)
assert d["allowBucket"] == ["s3:ListBucket"], d["allowBucket"]
for svc, objs in want.items():
    allows = [s for s in st[svc] if s["effect"] == "allow"]
    if not objs:
        assert allows == [], svc + " must have no allow statement: %r" % allows
    else:
        assert len(allows) == 2, svc + " allow statements"
        assert allows[0]["resources"] == ["OBJECTS"] and set(allows[0]["actions"]) == objs and len(allows[0]["actions"]) == len(objs), "%s object allow %r" % (svc, allows[0])
        assert allows[1]["resources"] == ["BUCKET"] and allows[1]["actions"] == ["s3:ListBucket"], svc + " bucket allow"
    assert not any("*" in a for s in allows for a in s["actions"]), svc + " wildcard in allow"
    assert "s3:CreateBucket" not in [a for s in allows for a in s["actions"]]
assert "s3:DeleteObject" not in {a for s in st["imaging"] for a in s["actions"] if s["effect"] == "allow"}, "imaging may delete"
PY
check "AC1/AC2 per-service allow sets: api/worker Get,Put,Delete,Abort + ListBucket; imaging Get,Put,Abort + ListBucket (no Delete); migrate none" $?

python3 - <<'PY'
import json, os
d = json.load(open(os.environ["DUMP"]))
want = """GetObjectVersion GetObjectVersionAttributes GetObjectVersionAcl GetObjectVersionTagging
GetObjectVersionTorrent ListBucketVersions DeleteObjectVersion DeleteObjectVersionTagging PutObjectVersionAcl
PutObjectVersionTagging PutBucketVersioning PutLifecycleConfiguration PutBucketPolicy DeleteBucketPolicy
DeleteBucket PutBucketAcl PutObjectAcl PutBucketPublicAccessBlock PutBucketOwnershipControls
PutReplicationConfiguration BypassGovernanceRetention
PutInventoryConfiguration PutEncryptionConfiguration PutBucketNotification PutBucketCORS PutObjectRetention PutObjectLegalHold""".split()
want = {"s3:" + w for w in want}
got = d["deny"]
assert len(want) == 27
assert len(got) == len(set(got)), "duplicate deny action"
missing = want - set(got)
assert not missing, "deny list drops " + ", ".join(sorted(missing))
assert set(got) == want, "extra deny actions " + str(set(got) - want)
assert not any("*" in a for a in got), "wildcard in deny"
for svc, sts in d["statements"].items():
    allowed = {a for s in sts if s["effect"] == "allow" for a in s["actions"]}
    assert not (set(got) & allowed), svc + ": an action is both allowed and denied"
PY
check "AC3 Deny list is exactly the 27 named actions (R3 + S-89 six), none also allowed, no wildcard" $?

python3 - <<'PY'
import json, os
d = json.load(open(os.environ["DUMP"]))
for svc, sts in d["statements"].items():
    deny = [s for s in sts if s["effect"] == "deny"]
    assert len(deny) == 1, svc + ": one deny statement"
    assert sts[-1] is not None and sts[-1]["effect"] == "deny", svc + ": Deny must be last"
    assert deny[0]["resources"] == ["BUCKET", "OBJECTS"], "%s deny must cover the bucket and arn/*: %r" % (svc, deny[0]["resources"])
    assert set(deny[0]["actions"]) == set(d["deny"]) and len(deny[0]["actions"]) == len(d["deny"]), svc + ": deny holds every FILES_DENY_ACTIONS entry"
doc = d["doc"]
assert doc["Statement"][-1]["Effect"] == "Deny" and doc["Statement"][-1]["Resource"] == ["arn:aws:s3:::w50-t-50-2-x", "arn:aws:s3:::w50-t-50-2-x/*"]
assert not any("s3:DeleteObject" in s["Action"] for s in doc["Statement"] if s["Effect"] == "Allow"), "imaging doc allows delete"
PY
check "AC3 every service: one Deny, last, on both the bucket and arn/*, holding every denied action" $?

# (b) anchor each service's permissions line to one exact form
python3 - "$SST" <<'PY'
import re, sys
raw = open(sys.argv[1]).read()
code = "\n".join(l for l in raw.split("\n") if not l.lstrip().startswith("//"))
def block(name):
    m = re.search(r'new sst\.aws\.(?:Service|Task)\("%s",.*?\n    \}\);' % name, code, re.S)
    assert m, name + " block missing"
    return m.group(0)
assert code.count("const filesObjects = $interpolate`${files.arn}/*`;") == 1, "filesObjects definition changed"
assert "filesAccess" not in code, "the shared filesAccess constant is back"
exact = {
  "Imaging": r'filesPermissionsFor\("imaging", files\.arn, filesObjects\)',
  "Api": r'\[\.\.\.filesPermissionsFor\("api", files\.arn, filesObjects\), kmsPermission\]',
  "Worker": r'\[\.\.\.filesPermissionsFor\("worker", files\.arn, filesObjects\), kmsPermission\]',
  "Migrate": r'\[\.\.\.filesPermissionsFor\("migrate", files\.arn, filesObjects\), kmsPermission\]',
}
for svc, pat in exact.items():
    b = block(svc)
    lines = re.findall(r'^      permissions: .*$', b, re.M)
    assert len(lines) == 1, svc + ": exactly one permissions line, got %d" % len(lines)
    assert re.fullmatch(r'      permissions: ' + pat + ',', lines[0]), svc + " permissions line is not the anchored form: " + lines[0]
    assert not re.search(r'^\s*link:', b, re.M), svc + " still has a link: (link grants s3:*)"
assert code.count("filesPermissionsFor(") == 4, "filesPermissionsFor used %d times" % code.count("filesPermissionsFor(")
assert not re.search(r'link:\s*\[[^\]]*files', code), "link: [files] is back somewhere"
assert "S3_BUCKET: files.name" in code, "S3_BUCKET no longer carries the bucket name"
PY
check "AC4(b) each service's permissions line matches one anchored form (no filter/map/slice), no link, S3_BUCKET still set" $?

# AC5 crash alarm
python3 - "$SST" <<'PY'
import json, os, re, sys
d = json.load(open(os.environ["DUMP"]))
raw = open(sys.argv[1]).read()
code = "\n".join(l for l in raw.split("\n") if not l.lstrip().startswith("//"))
assert d["msg"] == "unhandled rejection", "alarm message text is %r" % d["msg"]
assert d["pattern"] == '{ $.msg = "unhandled rejection" }', d["pattern"]
backend = os.environ["BACKEND_DIR"]
for f in ("src/api/server.ts", "src/worker/index.ts"):
    t = open(os.path.join(backend, f)).read()
    assert 'log.error("%s"' % d["msg"] in t, f + " does not log the alarm's message text"
a = d["alarm"]
assert a == {"metricName": "UnhandledRejection", "statistic": "Sum", "period": 300, "evaluationPeriods": 1,
             "threshold": 1, "comparisonOperator": "GreaterThanOrEqualToThreshold", "treatMissingData": "notBreaching"}, a
assert d["ns"] == "InvAI/demo", d["ns"]
assert d["api"] == "/invai/demo/api" and d["worker"] == "/invai/demo/worker", (d["api"], d["worker"])
def block(name):
    m = re.search(r'new sst\.aws\.(?:Service|Task)\("%s",.*?\n    \}\);' % name, code, re.S)
    assert m, name + " block missing"
    return m.group(0)
for svc, key in (("Api", "api"), ("Worker", "worker")):
    assert ('logging: { name: appLogGroupName(stage, "%s") }' % key) in block(svc), svc + " lacks the explicit log group name"
    f = re.search(r'new aws\.cloudwatch\.LogMetricFilter\(\s*"%sUnhandledRejection",\s*\{(.*?)\n      \},' % svc, code, re.S)
    assert f, svc + " metric filter missing"
    fb = f.group(1)
    assert ('logGroupName: appLogGroupName(stage, "%s")' % key) in fb, svc + " filter log group differs from the service's logging.name"
    assert "pattern: UNHANDLED_REJECTION_FILTER_PATTERN" in fb, svc + " filter pattern is not the shared constant"
    assert "metricTransformation: crashMetric" in fb, svc + " filter metric"
cm = re.search(r'const crashMetric = \{(.*?)\};', code, re.S)
assert cm and "UNHANDLED_REJECTION_ALARM.metricName" in cm.group(1) and "metricNamespace(stage)" in cm.group(1) and 'value: "1"' in cm.group(1), "crashMetric"
al = re.search(r'new aws\.cloudwatch\.MetricAlarm\(\s*"UnhandledRejectionAlarm",\s*\{(.*?)\n      \},', code, re.S)
assert al, "alarm missing"
ab = al.group(1)
assert "namespace: metricNamespace(stage)" in ab and "...UNHANDLED_REJECTION_ALARM" in ab, "alarm namespace/values"
assert "alarmActions: [opsAlerts.arn]" in ab and "okActions" not in ab, "alarm action"
assert code.count("MetricAlarm(") == 1, "exactly one alarm"
assert 'new aws.sns.Topic("OpsAlerts")' in code, "OpsAlerts topic"
assert not re.search(r'TopicSubscription|aws\.sns\.(?!Topic\()|aws\.ses|sst\.aws\.Email\([^)]*Alert', code), "an SNS subscription or other sink exists"
PY
check "AC5 metric filters on Api and Worker log groups (same constant as logging.name), exact message text, one alarm, topic without subscription" $?

echo "# $n checks"
exit $fail
