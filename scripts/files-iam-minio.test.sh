#!/usr/bin/env bash
# Semantic proof (T-49-2 part A, AC4) on local MinIO that the Files-bucket policy from
# infra/files-access.ts keeps current-object access and refuses old versions, version listing and
# bucket changes. The policy is generated from the SAME action lists sst.config.ts uses.
# Run: `bash scripts/files-iam-minio.test.sh` (needs the local stack: `pnpm local:up`).
#
# Safety: everything happens in the throwaway bucket w49-iam-<stamp> with a throwaway user and policy
# of the same prefix. The bucket name is printed before any write, any name that does not start with
# w49-iam- is refused, and a trap removes user, policy and every version in the bucket. It never
# touches invai-local, invai-test, invai-gate, invai-full or any server-wide setting.
# MINIO_URL points mc at another server (a dead one, http://127.0.0.1:1, proves it aborts before any
# write). bash 3.2 compatible.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="${W49_IAM_STAMP:-$(date +%Y%m%d%H%M%S)-$$}"
BUCKET="${W49_IAM_BUCKET:-w49-iam-$STAMP}"
USERNAME="w49-iam-u-$STAMP"
POLICY_A="w49-iam-pa-$STAMP"
POLICY_B="w49-iam-pb-$STAMP"
USERSECRET="w49-iam-secret-$STAMP"
URL="${MINIO_URL:-http://minio:9000}"
NET="${MINIO_NETWORK:-local_default}"

echo "bucket: $BUCKET (user $USERNAME, policies $POLICY_A $POLICY_B, server $URL)"
case "$BUCKET" in
  w49-iam-*) ;;
  *) echo "ABORT - bucket must start with w49-iam- (got '$BUCKET'); never invai-local, invai-test, invai-gate or invai-full"; exit 3 ;;
esac
MC_IMAGE="$(grep -E '^\s+image: quay.io/minio/mc@sha256:' "$HERE/../local/docker-compose.yml" | head -1 | awk '{print $2}')"
[ -n "$MC_IMAGE" ] || { echo "ABORT - mc image not found in local/docker-compose.yml"; exit 3; }

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
T="$(mktemp -d)"
chmod 755 "$T"

# mc runs in a container on the compose network. a = root user, u = the throwaway user.
mc_as() { # mc_as <a|u> mc-args...
  local who="$1"; shift
  local ak="invai" sk="invai-secret"
  if [ "$who" = u ]; then ak="$USERNAME"; sk="$USERSECRET"; fi
  docker run --rm -i --network "$NET" -v "$T:/w" -e AK="$ak" -e SK="$sk" -e URL="$URL" --entrypoint /bin/sh "$MC_IMAGE" \
    -c 'mc alias set s "$URL" "$AK" "$SK" >/dev/null 2>&1 && exec mc "$@"' sh "$@"
}
mca() { mc_as a "$@"; }
mcu() { mc_as u "$@"; }

created_bucket=0; created_user=0; created_policies=""
cleanup() {
  case "$BUCKET" in w49-iam-*) ;; *) rm -rf "$T"; return ;; esac
  if [ "$created_user" = 1 ]; then mca admin user rm s "$USERNAME" >/dev/null 2>&1; fi
  for p in $created_policies; do mca admin policy rm s "$p" >/dev/null 2>&1; done
  if [ "$created_bucket" = 1 ]; then
    mca rm --recursive --versions --force "s/$BUCKET" >/dev/null 2>&1
    mca rb --force "s/$BUCKET" >/dev/null 2>&1
    if mca ls "s/$BUCKET" >/dev/null 2>&1; then echo "CLEANUP FAILED - bucket $BUCKET still exists"; fail=1; else echo "cleanup - bucket $BUCKET, user and policy removed"; fi
  fi
  rm -rf "$T"
}
trap 'cleanup' EXIT

# reachability, read-only: abort here (nothing written) if the server is unreachable
if ! mca ls s >/dev/null 2>&1; then echo "ABORT - MinIO not reachable at $URL; nothing was written"; exit 1; fi

# policy generated from the shared module
node --experimental-strip-types --no-warnings -e '
const m = await import(process.argv[1]);
process.stdout.write(JSON.stringify(m.filesPolicyDocument(process.argv[2]), null, 1));
' "$HERE/../infra/files-access.ts" "$BUCKET" > "$T/policy.json" || { echo "ABORT - cannot generate policy"; exit 1; }
chmod 644 "$T/policy.json"

mca mb "s/$BUCKET" >/dev/null && created_bucket=1 || { echo "ABORT - cannot create bucket"; exit 1; }
mca version enable "s/$BUCKET" >/dev/null || bad "enable versioning (admin)"
# MinIO rejects action names it does not implement (for example s3:PutBucketAcl). Drop each one it
# names, say so, and prove the rest; the dropped ones are covered by the static test only.
DROPPED=""
create_policy() { # create_policy <policy name> <json file in $T>
  local out bad_action
  for _ in $(seq 1 30); do
    out="$(mca admin policy create s "$1" "/w/$2" 2>&1)" && { created_policies="$created_policies $1"; return 0; }
    bad_action="$(printf '%s' "$out" | sed -n "s/.*unsupported action '\(s3:[A-Za-z]*\)'.*/\1/p" | head -1)"
    [ -n "$bad_action" ] || { bad "create policy $1 ($out)"; return 1; }
    case " $DROPPED " in *" $bad_action "*) ;; *) DROPPED="$DROPPED $bad_action" ;; esac
    python3 - "$T/$2" "$bad_action" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
for s in p["Statement"]:
    s["Action"] = [a for a in s["Action"] if a != sys.argv[2]]
json.dump(p, open(sys.argv[1], "w"))
PY
  done
  bad "create policy $1 (too many unsupported actions)"; return 1
}
# Phase A policy: the generated one without the two Deny actions MinIO authorizes differently from
# AWS (see the end of this script). Phase B policy: the full generated one.
python3 - "$T/policy.json" "$T/policy-a.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
for s in p["Statement"]:
    if s["Effect"] == "Deny":
        s["Action"] = [a for a in s["Action"] if a not in ("s3:GetObjectVersion", "s3:ListBucketVersions")]
json.dump(p, open(sys.argv[2], "w"))
PY
chmod 644 "$T/policy-a.json"
create_policy "$POLICY_A" policy-a.json
create_policy "$POLICY_B" policy.json
echo "MinIO cannot express:${DROPPED:- (nothing)}"
mca admin user add s "$USERNAME" "$USERSECRET" >/dev/null && created_user=1 || bad "create user"

# two versions of one key, written by the admin; v1 is the "purged" old version
K=company/file.bin
printf 'version-one' > "$T/v1.bin"; printf 'version-two' > "$T/v2.bin"
mca cp /w/v1.bin "s/$BUCKET/$K" >/dev/null || bad "seed v1"
mca cp /w/v2.bin "s/$BUCKET/$K" >/dev/null || bad "seed v2"
VID1="$(mca ls --versions --json "s/$BUCKET/$K" | python3 -c '
import sys, json
vs = [json.loads(l) for l in sys.stdin if l.strip()]
vs = [v for v in vs if not v.get("isDeleteMarker")]
vs.sort(key=lambda v: v["lastModified"])
print(vs[0]["versionId"])')"
[ -n "$VID1" ] && echo "seeded: key $K, old version id $VID1" || bad "find old version id"

denied() { # denied <name> <command...>: must fail with AccessDenied, not some other error
  local name="$1"; shift
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'access denied\|AccessDenied\|insufficient permissions'; then ok "refused: $name"; else bad "refused: $name (rc=$rc: $(printf '%s' "$out" | head -c 160))"; fi
}
allowed() { local name="$1"; shift; local out; out="$("$@" 2>&1)"; local rc=$?; if [ "$rc" -eq 0 ]; then ok "allowed: $name"; else bad "allowed: $name (rc=$rc: $(printf '%s' "$out" | head -c 160))"; fi; }
attach_only() { # attach_only <policy>: the user holds exactly this policy
  local p
  for p in $created_policies; do mca admin policy detach s "$p" --user "$USERNAME" >/dev/null 2>&1; done
  mca admin policy attach s "$1" --user "$USERNAME" >/dev/null || bad "attach $1"
}

echo "--- phase A: policy without GetObjectVersion / ListBucketVersions (current-object path)"
attach_only "$POLICY_A"
printf 'user-wrote' > "$T/u.bin"
allowed "put current object" mcu cp /w/u.bin "s/$BUCKET/company/u.bin"
GOT="$(mcu cat "s/$BUCKET/company/u.bin" 2>&1)"; [ "$GOT" = "user-wrote" ] && ok "allowed: get current object (content matches)" || bad "get current object (got '$GOT')"
allowed "head current object" mcu stat "s/$BUCKET/company/u.bin"
allowed "list objects (ListBucket)" mcu ls "s/$BUCKET/company/"
allowed "list bucket root" mcu ls "s/$BUCKET"
allowed "delete current object" mcu rm "s/$BUCKET/company/u.bin"
# HEAD of a missing key must say 404 (needs ListBucket), not 403
OUT="$(mcu stat "s/$BUCKET/company/does-not-exist.bin" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'does not exist\|not found\|NoSuchKey' && ! printf '%s' "$OUT" | grep -qi 'access denied\|insufficient'; then ok "HEAD of a missing key answers 404, not 403"; else bad "HEAD missing key (rc=$RC: $(printf '%s' "$OUT" | head -c 160))"; fi
# control: without the GetObjectVersion Deny the old version IS readable, so phase B's refusal is that Deny
GOT="$(mcu cat --version-id "$VID1" "s/$BUCKET/$K" 2>&1)"; [ "$GOT" = "version-one" ] && ok "control: old version readable without the GetObjectVersion Deny" || bad "control old-version read (got '$GOT')"
denied "delete old version by id" mcu rm --version-id "$VID1" "s/$BUCKET/$K"
denied "put bucket versioning" mcu version suspend "s/$BUCKET"
denied "put lifecycle configuration" mcu ilm import "s/$BUCKET" < "$HERE/minio-lifecycle.json"
denied "put bucket policy (anonymous set)" mcu anonymous set download "s/$BUCKET"

echo "--- phase B: the full generated policy"
attach_only "$POLICY_B"
denied "get old version by id" mcu cat --version-id "$VID1" "s/$BUCKET/$K"
denied "delete old version by id" mcu rm --version-id "$VID1" "s/$BUCKET/$K"
denied "put bucket versioning" mcu version suspend "s/$BUCKET"
denied "put lifecycle configuration" mcu ilm import "s/$BUCKET" < "$HERE/minio-lifecycle.json"
denied "put bucket policy (anonymous set)" mcu anonymous set download "s/$BUCKET"

# the refused attempts changed nothing: the admin still reads the old version and versioning is on
OLD="$(mca cat --version-id "$VID1" "s/$BUCKET/$K" 2>&1)"; [ "$OLD" = "version-one" ] && ok "old version still intact after the refused attempts" || bad "old version intact (got '$OLD')"
mca version info "s/$BUCKET" 2>&1 | grep -q 'is enabled' && ok "versioning still enabled" || bad "versioning still enabled"

cat <<'NOTE'
--- not provable on MinIO (static test files-iam.test.sh covers them)
- s3:ListBucketVersions: MinIO authorizes ListObjectVersions with s3:ListBucket, so a Deny of it has no effect there.
- s3:GetObjectVersion: MinIO also requires it for a plain GET of a current object that has a version id
  (phase B refuses GET of the current object too). AWS S3 needs only s3:GetObject for a GET without
  versionId; that AWS behavior is documented, not reproduced here. Verify on the first staging deploy.
- DeleteBucket (mc checks the bucket is empty first), and the actions MinIO listed above as unsupported.
NOTE
exit $fail
