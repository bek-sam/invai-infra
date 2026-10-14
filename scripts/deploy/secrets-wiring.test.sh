#!/usr/bin/env bash
# Static check (T-51-2, B-355): every secret invai-backend `src/env.ts` declares with `secret(...)`
# is an `sst.Secret` in sst.config.ts, reaches api/worker (and only the right services) through
# SSM, and never sits in an `environment:` map, `backendEnvironment` or `link:`; or it is on the
# allowlist below with a reason. Run: `pnpm secrets:test`. Reads files only.
# INFRA_DIR overrides the infra checkout; BACKEND_ENV overrides the env.ts file (fixture mutants).
# bash 3.2 compatible; needs python3 (standard library only).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BACKEND_ENV="${BACKEND_ENV:-$INFRA_DIR/../invai-backend/src/env.ts}"
export INFRA_DIR BACKEND_ENV

exec python3 -I - "$INFRA_DIR/sst.config.ts" "$BACKEND_ENV" <<'PY'
import re, sys

sst = open(sys.argv[1]).read()
env_ts = open(sys.argv[2]).read()
fails, n = [], 0

def check(name, ok, why=""):
    global n
    n += 1
    if ok:
        print("ok %d - %s" % (n, name))
    else:
        print("not ok %d - %s%s" % (n, name, (": " + why) if why else ""))
        fails.append(name)

# Names the backend reads through secret(...) that are deliberately not SST secrets.
ALLOW = {
    "MARKET_MOCK_FAIL": "test-only outage switch, ignored in production",
    "FIELD_ENCRYPTION_LOCAL_MASTER_KEY": "provider `local` only; deployed stages use `static` (B-327)",
    "FIELD_ENCRYPTION_DATA_KEYS": "provider `local` only; deployed stages use `static` (B-327)",
    "MAIL_FROM": "not a secret; plain backendEnvironment",
}
# Names that must always be wired (they are not all declared with secret(...) in env.ts).
CORE_SECRET = ["BETTER_AUTH_SECRET", "FLOOR_TOKEN_SECRET", "FIELD_ENCRYPTION_KEY", "IMAGING_SHARED_SECRET"]
CORE_SSM = ["DATABASE_URL", "MIGRATION_DATABASE_URL", "REDIS_URL"]
PROVIDER7 = ["OPENAI_API_KEY", "SS_ACTIVEWEAR_ACCOUNT", "SS_ACTIVEWEAR_API_KEY", "CENSUS_API_KEY",
             "GOOGLE_TRENDS_API_KEY", "PINTEREST_API_KEY", "JUNGLE_SCOUT_API_KEY"]

def block(text, start):
    """Text from the first opening bracket at/after start to its match."""
    i = min(x for x in (text.find(c, start) for c in "{(") if x >= 0)
    depth = 0
    for j in range(i, len(text)):
        if text[j] in "{(":
            depth += 1
        elif text[j] in "})":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return text[i:]

declared = sorted(set(re.findall(r"^\s+([A-Z][A-Z0-9_]*):\s*secret\(", env_ts, re.M)))
check("env.ts: secret(...) names parsed", len(declared) >= 20, "found %d" % len(declared))
need = [d for d in declared if d not in ALLOW] + [c for c in CORE_SECRET if c not in declared]

m = re.search(r"const secret = \{", sst)
secret_map = block(sst, m.start()) if m else ""
check("sst.config.ts has the `secret = {` map", bool(m))
map_keys = dict(re.findall(r"^\s+([A-Z][A-Z0-9_]*):\s*(required|providerKey|optionalKey)\(", secret_map, re.M))

pick_lists = [set(re.findall(r'"([A-Z][A-Z0-9_]*)"', block(sst, p.start()))) for p in re.finditer(r"\bpick\(", sst)]
picked = set().union(*pick_lists) if pick_lists else set()

# Resolve which SSM names each ECS service/task gets.
named = {}
for pm in re.finditer(r"const (\w+) = pick\(", sst):
    named[pm.group(1)] = set(re.findall(r'"([A-Z][A-Z0-9_]*)"', block(sst, pm.end() - 1)))
services = {}
starts = [(s.group(1), s.start()) for s in re.finditer(r'new sst\.aws\.(?:Service|Task)\("(\w+)"', sst)]
for i, (svc, st) in enumerate(starts):
    end = starts[i + 1][1] if i + 1 < len(starts) else len(sst)
    chunk = sst[st:end]
    sm = re.search(r"^\s+ssm:\s*", chunk, re.M)
    if not sm:
        continue
    expr = block(chunk, sm.end()) if chunk[sm.end()] == "{" else chunk[sm.end():chunk.find("\n", sm.end())]
    names = set()
    for ref in re.findall(r"\.\.\.(\w+)(?!\()", expr) + ([chunk[sm.end():].split(",")[0].strip()] if chunk[sm.end()] != "{" else []):
        names |= named.get(ref, set())
    for pk in re.finditer(r"pick\(", expr):
        names |= set(re.findall(r'"([A-Z][A-Z0-9_]*)"', block(expr, pk.start())))
    services[svc] = names
for s in ("Api", "Worker", "Migrate", "Imaging"):
    check("service %s has an ssm map" % s, s in services)

# Environment-like blocks: every `environment:` map, backendEnvironment, every `link:`.
env_blocks = [block(sst, e.end() - 1) for e in re.finditer(r"\benvironment:\s*\{", sst)]
bm = re.search(r"const backendEnvironment = \{", sst)
if bm:
    env_blocks.append(block(sst, bm.start()))
env_blocks += [block(sst, e.end() - 1) for e in re.finditer(r"\blink:\s*\[", sst)]
check("environment/link blocks found", len(env_blocks) >= 4, "found %d" % len(env_blocks))
env_text = "\n".join(env_blocks)

bad_key = [x for x in need if x not in map_keys]
check("every needed secret is in the `secret = {` map", not bad_key, ", ".join(bad_key))
bad_pick = [x for x in need if x not in picked]
check("every needed secret is inside a pick(...) list", not bad_pick, ", ".join(bad_pick))
API_ONLY = {"INTERNAL_ADMIN_TOKEN"}  # operator routes live in the api process only
bad_svc = [x for x in need if x not in services.get("Api", set())
           or (x not in API_ONLY and x not in services.get("Worker", set()))]
check("every needed secret reaches Api ssm (and Worker, except the api-only token)", not bad_svc, ", ".join(bad_svc))
bad_env = [x for x in need + CORE_SSM + list(ALLOW)
           if x not in ("MAIL_FROM",) and re.search(r"\b%s\b" % x, env_text)]
check("no secret appears in an environment: map, backendEnvironment or link:", not bad_env, ", ".join(bad_env))
bad_ref = [x for x in need if re.search(r"\bsecret\.%s\b" % x, sst)]
check("no `secret.NAME.value` use outside the SSM loop", not bad_ref, ", ".join(bad_ref))

core_missing = [x for x in CORE_SECRET if x not in map_keys or x not in picked]
check("core secrets are in the map and a pick list", not core_missing, ", ".join(core_missing))
core_ssm_missing = [x for x in CORE_SSM if not re.search(r'toSsm\("%s"' % x, sst) or x not in picked]
check("DATABASE_URL, MIGRATION_DATABASE_URL, REDIS_URL are toSsm + picked", not core_ssm_missing, ", ".join(core_ssm_missing))

# Optional names default to a blank on every stage.
opt = PROVIDER7 + ["INTERNAL_ADMIN_TOKEN"]
bad_opt = [x for x in opt if map_keys.get(x) != "optionalKey"]
check("the 8 optional names use optionalKey", not bad_opt, ", ".join(bad_opt))
check("optionalKey defaults to a single space on every stage",
      re.search(r'const optionalKey = \(name: string\) => new sst\.Secret\(name, " "\);', sst) is not None)

# Least privilege.
for svc in ("Migrate", "Imaging"):
    leak = [x for x in opt if x in services.get(svc, set())]
    check("%s ssm has none of the 8 optional names" % svc, not leak, ", ".join(leak))
check("INTERNAL_ADMIN_TOKEN is in Api ssm only",
      "INTERNAL_ADMIN_TOKEN" in services.get("Api", set()) and "INTERNAL_ADMIN_TOKEN" not in services.get("Worker", set()))
miss = [x for x in PROVIDER7 if x not in services.get("Worker", set())]
check("Worker ssm has the 7 provider keys", not miss, ", ".join(miss))

stale = [a for a in ALLOW if a not in declared]
check("allowlist names still exist in env.ts (no stale entries)", not stale, ", ".join(stale))

print("%d checks, %d failed" % (n, len(fails)))
sys.exit(1 if fails else 0)
PY
