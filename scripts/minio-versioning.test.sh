#!/usr/bin/env bash
# Hermetic proof (T-43-1, B-398) that the local MinIO setup keeps old versions and can restore one.
# Run: `bash scripts/minio-versioning.test.sh` (needs the local stack up: `pnpm local:up`).
# Everything happens in the throwaway bucket invai-w43-probe, created with the same commands as the
# minio-init service and always removed at the end. It refuses to touch invai-local or invai-full,
# and never lists, writes or deletes in them. bash 3.2 compatible.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUCKET="${MINIO_PROBE_BUCKET:-invai-w43-probe}"
case "$BUCKET" in
  invai-w43-probe*) ;;
  *) echo "ABORT - probe bucket must start with invai-w43-probe (got '$BUCKET'); never invai-local or invai-full"; exit 3 ;;
esac
MC_IMAGE="$(grep -E '^\s+image: quay.io/minio/mc@sha256:' "$HERE/../local/docker-compose.yml" | head -1 | awk '{print $2}')"
NET="${MINIO_NETWORK:-local_default}"
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
T="$(mktemp -d)"
# mc runs in a container on the compose network; the alias is set fresh on each call.
mc() { docker run --rm -i --network "$NET" -v "$T:/w" -v "$HERE/minio-lifecycle.json:/lifecycle.json:ro" --entrypoint /bin/sh "$MC_IMAGE" -c 'mc alias set local http://minio:9000 invai invai-secret >/dev/null && exec mc "$@"' sh "$@"; }
cleanup() { mc rb --force "local/$BUCKET" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

# static checks on the compose file (the service that runs on every `compose up`)
C="$HERE/../local/docker-compose.yml"
svc="$(awk '/^  minio-init:/{f=1;next} f&&/^  [a-z]/{f=0} f' "$C")"
printf '%s' "$svc" | grep -q 'mc version enable local/invai-local' && ok "minio-init enables versioning" || bad "minio-init enables versioning"
printf '%s' "$svc" | grep -q 'mc ilm import local/invai-local' && ok "minio-init imports the lifecycle (idempotent, not ilm rule add)" || bad "minio-init imports the lifecycle"
printf '%s' "$svc" | grep -q 'ilm rule add' && bad "minio-init must not use ilm rule add" || ok "no ilm rule add"
[ -n "$MC_IMAGE" ] && ok "mc image pinned by digest" || bad "mc image pinned by digest"
python3 - "$HERE/minio-lifecycle.json" <<'PY' && ok "lifecycle json: one rule housekeeping, 7 days, delete markers" || bad "lifecycle json shape"
import json,sys
r=json.load(open(sys.argv[1]))["Rules"]
assert len(r)==1 and r[0]["ID"]=="housekeeping" and r[0]["NoncurrentVersionExpiration"]["NoncurrentDays"]==7 and r[0]["Expiration"]["ExpiredObjectDeleteMarker"] is True
PY

if ! mc ls local >/dev/null 2>&1; then echo "SKIP - MinIO not reachable on network $NET (start the stack: pnpm local:up)"; exit 1; fi
mc rb --force "local/$BUCKET" >/dev/null 2>&1   # leftovers of an aborted run (probe bucket only)
# the same commands as minio-init, twice (idempotent)
for i in 1 2; do
  mc mb --ignore-existing "local/$BUCKET" >/dev/null && mc anonymous set none "local/$BUCKET" >/dev/null \
    && mc version enable "local/$BUCKET" >/dev/null && mc ilm import "local/$BUCKET" < "$HERE/minio-lifecycle.json" >/dev/null || bad "setup run $i"
done
mc version info "local/$BUCKET" 2>&1 | grep -q 'is enabled' && ok "versioning enabled on probe bucket" || bad "versioning enabled"
mc ilm rule ls --json "local/$BUCKET" 2>/dev/null | python3 -c 'import sys,json
r=json.loads(sys.stdin.readline())["config"]["Rules"]
print("ok" if len(r)==1 and r[0]["ID"]=="housekeeping" and r[0]["NoncurrentVersionExpiration"]["NoncurrentDays"]==7 and r[0]["Expiration"]["ExpiredObjectDeleteMarker"] else "bad:%d" % len(r))' > "$T/rule.txt"
eq "exactly one rule (housekeeping, 7 days, delete markers) after two runs" "$(cat "$T/rule.txt")" "ok"

# recovery: put, delete, list versions, restore, read back byte-identical
head -c 100000 /dev/urandom > "$T/orig.bin"; want="$(shasum -a 256 < "$T/orig.bin" | cut -d' ' -f1)"
K=probe/object.bin
mc cp /w/orig.bin "local/$BUCKET/$K" >/dev/null && mc rm "local/$BUCKET/$K" >/dev/null || bad "put and delete"
eq "deleted object is not listed" "$(mc ls "local/$BUCKET/probe/" 2>/dev/null | wc -l | tr -d ' ')" "0"
vid="$(mc ls --versions --json "local/$BUCKET/$K" | python3 -c 'import sys,json
for l in sys.stdin:
    d=json.loads(l)
    if not d.get("isDeleteMarker"): print(d["versionId"])')"
[ -n "$vid" ] && ok "old version listed with a version id" || bad "old version listed"
mc cp --version-id "$vid" "local/$BUCKET/$K" "local/$BUCKET/$K" >/dev/null && ok "restored by version id" || bad "restore by version id"
eq "restored bytes identical" "$(mc cat "local/$BUCKET/$K" | shasum -a 256 | cut -d' ' -f1)" "$want"
# overwrite keeps the previous version too
head -c 1000 /dev/urandom > "$T/new.bin"; mc cp /w/new.bin "local/$BUCKET/$K" >/dev/null
n="$(mc ls --versions --json "local/$BUCKET/$K" | wc -l | tr -d ' ')"
[ "$n" -ge 3 ] && ok "overwrite keeps earlier versions ($n listed)" || bad "overwrite keeps versions ($n)"
mc rb --force "local/$BUCKET" >/dev/null 2>&1; trap 'rm -rf "$T"' EXIT
mc ls "local/$BUCKET" >/dev/null 2>&1 && bad "probe bucket removed" || ok "probe bucket removed"
[ "$fail" -eq 0 ] && echo "ALL OK" || echo "FAILED"
exit "$fail"
