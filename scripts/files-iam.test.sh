#!/usr/bin/env bash
# Static checks (T-49-2 part A, AC1-AC3 and AC5) that the app's services cannot read, list or delete
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
  allowObject: m.FILES_ALLOW_OBJECT_ACTIONS,
  allowBucket: m.FILES_ALLOW_BUCKET_ACTIONS,
  deny: m.FILES_DENY_ACTIONS,
  statements: m.filesStatements(B, O),
  doc: m.filesPolicyDocument("w49-iam-x"),
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

# AC1: every S3 call the code makes (backend lib/s3.ts + callers, zip-readme multipart, privacy export,
# imaging storage.py) maps to one of these actions. The allow side must cover all of them.
python3 - <<'PY'
import json, os
d = json.load(open(os.environ["DUMP"]))
need_obj = {"s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"}
need_bucket = {"s3:ListBucket"}
st = d["statements"]
obj = next(s for s in st if s["effect"] == "allow" and s["resources"] == ["OBJECTS"])
bkt = next(s for s in st if s["effect"] == "allow" and s["resources"] == ["BUCKET"])
assert need_obj <= set(obj["actions"]), "object allow misses " + str(need_obj - set(obj["actions"]))
assert need_bucket <= set(bkt["actions"]), "bucket allow misses " + str(need_bucket - set(bkt["actions"]))
PY
check "AC1 allow side covers every action the app needs (object actions on arn/*, ListBucket on arn)" $?

python3 - <<'PY'
import json, os
d = json.load(open(os.environ["DUMP"]))
allowed = set(d["allowObject"]) | set(d["allowBucket"])
assert set(d["allowObject"]) == {"s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"}, d["allowObject"]
assert set(d["allowBucket"]) == {"s3:ListBucket"}, d["allowBucket"]
assert not any("*" in a for a in allowed), "wildcard in allow"
assert "s3:CreateBucket" not in allowed
PY
check "AC1 allow list is exactly the five actions, no wildcard, no CreateBucket" $?

python3 - <<'PY'
import json, os
d = json.load(open(os.environ["DUMP"]))
want = """GetObjectVersion GetObjectVersionAttributes GetObjectVersionAcl GetObjectVersionTagging
GetObjectVersionTorrent ListBucketVersions DeleteObjectVersion DeleteObjectVersionTagging PutObjectVersionAcl
PutObjectVersionTagging PutBucketVersioning PutLifecycleConfiguration PutBucketPolicy DeleteBucketPolicy
DeleteBucket PutBucketAcl PutObjectAcl PutBucketPublicAccessBlock PutBucketOwnershipControls
PutReplicationConfiguration BypassGovernanceRetention""".split()
want = {"s3:" + w for w in want}
got = d["deny"]
assert len(got) == len(set(got)), "duplicate deny action"
missing = want - set(got)
assert not missing, "deny list drops " + ", ".join(sorted(missing))
assert set(got) == want, "extra deny actions " + str(set(got) - want)
assert not any("*" in a for a in got), "wildcard in deny"
assert not (set(got) & (set(d["allowObject"]) | set(d["allowBucket"]))), "an action is both allowed and denied"
PY
check "AC2 Deny list is exactly the 21 named actions (R3), none also allowed, no wildcard" $?

python3 - <<'PY'
import json, os
d = json.load(open(os.environ["DUMP"]))
deny = [s for s in d["statements"] if s["effect"] == "deny"]
assert len(deny) == 1, "one deny statement"
assert deny[0]["resources"] == ["BUCKET", "OBJECTS"], "deny must cover the bucket and arn/*: %r" % deny[0]["resources"]
allow = [s for s in d["statements"] if s["effect"] == "allow"]
assert [s["resources"] for s in allow] == [["OBJECTS"], ["BUCKET"]], "allow resources"
doc = d["doc"]
assert any(s["Effect"] == "Deny" and s["Resource"] == ["arn:aws:s3:::w49-iam-x", "arn:aws:s3:::w49-iam-x/*"] for s in doc["Statement"])
PY
check "AC3 Deny resource is both the bucket and arn/*; allows are object-level on arn/* and ListBucket on arn" $?

python3 - "$SST" <<'PY'
import re, sys
raw = open(sys.argv[1]).read()
code = "\n".join(l for l in raw.split("\n") if not l.lstrip().startswith("//"))
def block(name):
    m = re.search(r'new sst\.aws\.(?:Service|Task)\("%s",.*?\n    \}\);' % name, code, re.S)
    assert m, name + " block missing"
    return m.group(0)
assert "const filesAccess = filesStatements(files.arn, $interpolate`${files.arn}/*`);" in code, "filesAccess definition changed"
for svc in ("Imaging", "Api", "Worker", "Migrate"):
    b = block(svc)
    m = re.search(r'^      permissions: (.*),$', b, re.M)
    assert m, svc + " has no permissions line"
    assert re.search(r'(^|[\[\s,.])filesAccess\b', m.group(1)), svc + " permissions lack filesAccess: " + m.group(1)
    assert "...filesAccess" in m.group(1) or m.group(1).strip() == "filesAccess", svc + " must spread filesAccess"
    assert not re.search(r'^\s*link:', b, re.M), svc + " still has a link: (link grants s3:*)"
assert not re.search(r'link:\s*\[[^\]]*files', code), "link: [files] is back somewhere"
assert "S3_BUCKET: files.name" in code, "S3_BUCKET no longer carries the bucket name"
PY
check "AC2 Imaging, Api, Worker and Migrate each spread filesAccess; none keeps link; S3_BUCKET still set" $?

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
