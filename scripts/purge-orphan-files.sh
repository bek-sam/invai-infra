#!/usr/bin/env bash
# One-off purge of orphan files in one named local MinIO bucket (T-42-2, B-391; T-46-2, S-84).
#
#   bash scripts/purge-orphan-files.sh --bucket <name>            dry run: counts and bytes per class, deletes nothing
#   bash scripts/purge-orphan-files.sh --bucket <name> --apply    deletes the orphan class
#
# --bucket is required (no default). A dry run reads any local bucket, invai-local included. --apply is
# refused unless the bucket is on the fixed allow-list (exactly invai-gate); the dev bucket invai-local is
# not on it, because deleting there is the owner's decision (OI-53). The bucket is passed to the S3 helper
# on every call (an exported S3_BUCKET can not override it) and every output line names it.
#
# A top-level prefix is deleted only when ALL hold:
#   (a) it is a lowercase UUID,
#   (b) it is not a company id in ANY local database that has a `companies` table (discovered, not
#       hard-coded; invai, invai_test, invai_gate, ...), and
#   (c) no object under it changed in the last 6 hours (a running test's files survive).
# Non-UUID prefixes, root-level objects and other buckets are listed, never deleted. The script
# refuses to run when it cannot read the company list of `invai` (an empty list is a refusal) or
# of any other database that has the table. Only local containers and a localhost MinIO are used.
# bash 3.2 compatible.
set -uo pipefail

PURGE_TOOLS_DIR="${PURGE_TOOLS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate}"
PURGE_PG_CONTAINER="${PURGE_PG_CONTAINER:-local-postgres-1}"
PURGE_MIN_AGE_SECONDS=21600
PURGE_APPLY_BUCKETS="invai-gate"
PURGE_BUCKET=""

# Every s3tool call names its bucket itself: S3_BUCKET from .env or the gate must not decide it.
purge_s3() {
  if [ -n "${PURGE_S3_TOOL:-}" ]; then S3_BUCKET="$PURGE_BUCKET" "$PURGE_S3_TOOL" "$@"; else S3_BUCKET="$PURGE_BUCKET" node "$PURGE_TOOLS_DIR/s3tool.mjs" "$@"; fi
}

purge_apply_allowed() { # purge_apply_allowed <bucket>
  local b
  for b in $PURGE_APPLY_BUCKETS; do [ "$b" = "$1" ] && return 0; done
  return 1
}

purge_psql() { # purge_psql <db> <sql>
  docker exec "$PURGE_PG_CONTAINER" psql -U invai -d "$1" -v ON_ERROR_STOP=1 -Atc "$2"
}

# Databases of the local server that a company id could live in.
purge_databases() {
  purge_psql postgres "select datname from pg_database where datname <> 'postgres' and datname <> 'template0' and datname <> 'template1'"
}

# Company ids of one database, one per line; prints nothing and returns 0 when it has no companies table.
purge_company_ids() {
  local has
  has="$(purge_psql "$1" "select to_regclass('public.companies') is not null")" || return 1
  [ "$has" = t ] || return 0
  purge_psql "$1" "select id from companies"
}

purge_valid_prefix() { # exactly a lowercase UUID plus the trailing slash
  case "$1" in
    ????????-????-????-????-????????????/) ;;
    *) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/$'
}

# purge_collect_live <file>: writes every discovered company id to <file>. Returns 1 (a refusal) when
# the databases cannot be listed, any database cannot be read, or `invai` has no companies.
purge_collect_live() {
  local out="$1" dbs db ids invai_n=0
  : >"$out"; : >"$out.invai"
  if ! dbs="$(purge_databases)" || [ -z "$dbs" ]; then
    echo "refused: cannot list the local databases" >&2
    return 1
  fi
  for db in $dbs; do
    if ! ids="$(purge_company_ids "$db")"; then
      echo "refused: cannot read the company list of database '$db'" >&2
      return 1
    fi
    [ -n "$ids" ] && printf '%s\n' "$ids" >>"$out"
    if [ "$db" = invai ]; then
      invai_n="$(printf '%s' "$ids" | grep -c . || true)"
      [ -n "$ids" ] && printf '%s\n' "$ids" >"$out.invai"
    fi
  done
  if [ "${invai_n:-0}" -eq 0 ]; then
    echo "refused: the company list of the dev database invai is empty or unreadable" >&2
    return 1
  fi
  return 0
}

# purge_in_live <prefix> <live file>: 0 = live, 1 = not live. Any grep failure (exit above 1, such as
# a missing or unreadable file) is returned as 2 and is a refusal for the caller, never "not live".
purge_in_live() {
  grep -qxF "$1" "$2" 2>/dev/null
  case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# purge_check_live <live file> <invai ids file>: refuses (returns 1) when the live file is missing,
# empty or unreadable, or lacks any of the invai company ids that were just read.
purge_check_live() {
  local live="$1" id rc
  if [ ! -s "$live" ]; then echo "refused: the live company file is missing or empty" >&2; return 1; fi
  if [ ! -s "$2" ]; then echo "refused: the invai id file is missing or empty" >&2; return 1; fi
  while IFS= read -r id; do
    purge_in_live "$id" "$live"; rc=$?
    if [ $rc -ne 0 ]; then echo "refused: the live company file lacks invai id '$id' (check $rc)" >&2; return 1; fi
  done <"$2"
  return 0
}

# purge_plan <live file> <now epoch>: reads `scan` TSV on stdin, writes
# "<class>\t<prefix>\t<objects>\t<bytes>" with class orphan | live | recent | non-uuid | root.
purge_plan() {
  local live="$1" now="$2" p n b t rc
  while IFS=$'\t' read -r p n b t; do
    if [ "$p" = "(root)" ]; then echo "root	$p	$n	$b"; continue; fi
    if ! purge_valid_prefix "$p/"; then echo "non-uuid	$p	$n	$b"; continue; fi
    purge_in_live "$p" "$live"; rc=$?
    if [ $rc -gt 1 ]; then echo "refused: cannot read the live company file" >&2; return 1; fi
    if [ $rc -eq 0 ]; then echo "live	$p	$n	$b"; continue; fi
    if [ $((now - t)) -lt "$PURGE_MIN_AGE_SECONDS" ]; then echo "recent	$p	$n	$b"; continue; fi
    echo "orphan	$p	$n	$b"
  done
}

purge_main() {
  local apply=0 arg tmp live scan plan now c n b total_n total_b rc want_bucket=0
  PURGE_BUCKET=""
  for arg in "$@"; do
    if [ $want_bucket -eq 1 ]; then
      if [ -n "$PURGE_BUCKET" ]; then echo "usage: --bucket given twice" >&2; return 2; fi
      PURGE_BUCKET="$arg"; want_bucket=0; continue
    fi
    case "$arg" in
      --apply) apply=1 ;;
      --bucket) want_bucket=1 ;;
      *) echo "usage: purge-orphan-files.sh --bucket <name> [--apply]" >&2; return 2 ;;
    esac
  done
  if [ $want_bucket -eq 1 ] || [ -z "$PURGE_BUCKET" ]; then
    echo "refused: --bucket <name> is required (no default); usage: purge-orphan-files.sh --bucket <name> [--apply]" >&2
    return 2
  fi
  if ! printf '%s' "$PURGE_BUCKET" | grep -Eq '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'; then
    echo "refused: '$PURGE_BUCKET' is not a bucket name" >&2
    return 2
  fi
  if [ $apply -eq 1 ] && ! purge_apply_allowed "$PURGE_BUCKET"; then
    echo "refused: --apply is not allowed in bucket '$PURGE_BUCKET' (allowed: $PURGE_APPLY_BUCKETS); to ask for deletes there, answer OI-53 in invai-docs/owner-inbox.md" >&2
    return 1
  fi
  tmp="$(mktemp -d)"; live="$tmp/live"; scan="$tmp/scan"; plan="$tmp/plan"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  purge_collect_live "$live" || return 1
  purge_check_live "$live" "$live.invai" || return 1
  if ! purge_s3 scan >"$scan"; then echo "refused: cannot scan bucket $PURGE_BUCKET" >&2; return 1; fi
  now="${PURGE_NOW:-$(date +%s)}"
  purge_plan "$live" "$now" <"$scan" >"$plan" || return 1

  echo "mode: $([ $apply -eq 1 ] && echo APPLY || echo 'dry run (nothing is deleted)'); bucket $PURGE_BUCKET; company ids known: $(sort -u "$live" | grep -c .)"
  for c in orphan recent live non-uuid root; do
    n=0; b=0
    while IFS=$'\t' read -r cls p o by; do
      [ "$cls" = "$c" ] || continue
      n=$((n + 1)); b=$((b + by))
    done <"$plan"
    printf '%-9s prefixes %6d  bytes %14d  (bucket %s)\n' "$c" "$n" "$b" "$PURGE_BUCKET"
  done
  echo "other buckets than $PURGE_BUCKET (listed, never deleted):"
  purge_s3 buckets 2>/dev/null | grep -vxF "$PURGE_BUCKET" | sed 's/^/  /' || true

  if [ $apply -eq 0 ]; then return 0; fi
  total_n=0; total_b=0
  while IFS=$'\t' read -r cls p o by; do
    [ "$cls" = orphan ] || continue
    # last look before every delete: shape and live set again
    purge_check_live "$live" "$live.invai" || return 1
    purge_valid_prefix "$p/" || { echo "refused prefix '$p/'" >&2; continue; }
    purge_in_live "$p" "$live"; rc=$?
    if [ $rc -ne 1 ]; then echo "refused prefix '$p/': live check said $rc" >&2; continue; fi
    if purge_s3 delete-prefix "$p/" >/dev/null; then
      total_n=$((total_n + 1)); total_b=$((total_b + by))
    else
      echo "delete of '$p/' in bucket $PURGE_BUCKET failed" >&2
    fi
  done <"$plan"
  echo "deleted $total_n prefixes, $total_b bytes from bucket $PURGE_BUCKET"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then purge_main "$@"; exit $?; fi
