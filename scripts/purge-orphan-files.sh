#!/usr/bin/env bash
# One-off purge of orphan files in the local MinIO bucket invai-local (T-42-2, B-391).
#
#   bash scripts/purge-orphan-files.sh            dry run: counts and bytes per class, deletes nothing
#   bash scripts/purge-orphan-files.sh --apply    deletes the orphan class
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

purge_s3() {
  if [ -n "${PURGE_S3_TOOL:-}" ]; then "$PURGE_S3_TOOL" "$@"; else node "$PURGE_TOOLS_DIR/s3tool.mjs" "$@"; fi
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
  : >"$out"
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
    [ "$db" = invai ] && invai_n="$(printf '%s' "$ids" | grep -c . || true)"
  done
  if [ "${invai_n:-0}" -eq 0 ]; then
    echo "refused: the company list of the dev database invai is empty or unreadable" >&2
    return 1
  fi
  return 0
}

# purge_plan <live file> <now epoch>: reads `scan` TSV on stdin, writes
# "<class>\t<prefix>\t<objects>\t<bytes>" with class orphan | live | recent | non-uuid | root.
purge_plan() {
  local live="$1" now="$2" p n b t
  while IFS=$'\t' read -r p n b t; do
    if [ "$p" = "(root)" ]; then echo "root	$p	$n	$b"; continue; fi
    if ! purge_valid_prefix "$p/"; then echo "non-uuid	$p	$n	$b"; continue; fi
    if grep -qxF "$p" "$live"; then echo "live	$p	$n	$b"; continue; fi
    if [ $((now - t)) -lt "$PURGE_MIN_AGE_SECONDS" ]; then echo "recent	$p	$n	$b"; continue; fi
    echo "orphan	$p	$n	$b"
  done
}

purge_main() {
  local apply=0 arg tmp live scan plan now c n b total_n total_b
  for arg in "$@"; do
    case "$arg" in
      --apply) apply=1 ;;
      *) echo "usage: purge-orphan-files.sh [--apply]" >&2; return 2 ;;
    esac
  done
  tmp="$(mktemp -d)"; live="$tmp/live"; scan="$tmp/scan"; plan="$tmp/plan"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  purge_collect_live "$live" || return 1
  if ! purge_s3 scan >"$scan"; then echo "refused: cannot scan the bucket" >&2; return 1; fi
  now="${PURGE_NOW:-$(date +%s)}"
  purge_plan "$live" "$now" <"$scan" >"$plan"

  echo "mode: $([ $apply -eq 1 ] && echo APPLY || echo 'dry run (nothing is deleted)'); bucket invai-local; company ids known: $(sort -u "$live" | grep -c .)"
  for c in orphan recent live non-uuid root; do
    n=0; b=0
    while IFS=$'\t' read -r cls p o by; do
      [ "$cls" = "$c" ] || continue
      n=$((n + 1)); b=$((b + by))
    done <"$plan"
    printf '%-9s prefixes %6d  bytes %14d\n' "$c" "$n" "$b"
  done
  echo "other buckets (listed, never deleted):"
  purge_s3 buckets 2>/dev/null | grep -vx 'invai-local' | sed 's/^/  /' || true

  if [ $apply -eq 0 ]; then return 0; fi
  total_n=0; total_b=0
  while IFS=$'\t' read -r cls p o by; do
    [ "$cls" = orphan ] || continue
    # last look before every delete: shape and live set again
    purge_valid_prefix "$p/" || { echo "refused prefix '$p/'" >&2; continue; }
    if grep -qxF "$p" "$live"; then echo "refused live company prefix '$p/'" >&2; continue; fi
    if purge_s3 delete-prefix "$p/" >/dev/null; then
      total_n=$((total_n + 1)); total_b=$((total_b + by))
    else
      echo "delete of '$p/' failed" >&2
    fi
  done <"$plan"
  echo "deleted $total_n prefixes, $total_b bytes"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then purge_main "$@"; exit $?; fi
