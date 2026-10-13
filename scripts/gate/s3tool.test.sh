#!/usr/bin/env bash
# Tests for the s3tool endpoint check (T-46-2, S-83). bash 3.2 compatible.
# Every endpoint below points at 127.0.0.1:1 (nothing listens); a refusal must come from s3tool's own
# check (exit 2, "s3tool: endpoint ..."), before any request, never from a connection error.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${S3TOOL_SRC:-$HERE/s3tool.mjs}"
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/share/pnpm:$PATH"
unset S3_BUCKET GATE_S3_TOOL PURGE_S3_TOOL

t() { # t <endpoint>: prints "rc|stderr first line"
  local out rc
  out="$(S3_ENDPOINT="$1" node "$TOOL" buckets 2>&1 >/dev/null)"; rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$out" | head -n1)"
}
refused() { # refused <label> <endpoint> <message fragment>
  local r; r="$(t "$2")"
  case "$r" in "2|s3tool: endpoint "*"$3"*) ok "refused ($1): $2" ;; *) bad "refused ($1): $2 (got '$r')" ;; esac
}

r="$(t http://127.0.0.1:1)"
case "$r" in 2*) bad "the endpoint is not dead; ABORT ($r)"; exit 3 ;; esac
full="$(S3_ENDPOINT=http://127.0.0.1:1 node "$TOOL" buckets 2>&1)"
case "$full" in *ECONNREFUSED*|*"connect "*) ok "a bare endpoint passes the check and reaches the (dead) socket" ;; *) bad "bare endpoint ($r)" ;; esac
r="$(t http://127.0.0.1:1/)"
case "$r" in 2*) bad "trailing slash refused ($r)" ;; *) ok "a lone trailing slash is accepted" ;; esac

refused path http://127.0.0.1:1/invai-local "path"
refused "nested path" http://127.0.0.1:1/a/b "path"
refused query 'http://127.0.0.1:1/?bucket=invai-local' "query"
refused "empty query" 'http://127.0.0.1:1/?' "query"
refused fragment 'http://127.0.0.1:1/#invai-local' "fragment"
refused "empty fragment" 'http://127.0.0.1:1#' "fragment"
refused "user info" 'http://user:pass@127.0.0.1:1' "user info"
refused "user only" 'http://user@127.0.0.1:1' "user info"
refused scheme ftp://127.0.0.1:1 "scheme"
refused "file scheme" file:///tmp "scheme"
refused "not a url" garbage "not a URL"
r="$(t http://example.com:9000)"
case "$r" in "2|s3tool: endpoint host"*) ok "a non-local host is still refused" ;; *) bad "non-local host ($r)" ;; esac
exit $fail
