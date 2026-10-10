#!/usr/bin/env python3
"""Helper for `pnpm scan` (scripts/scan.sh). Python 3 standard library only.

  ignores.py check  <ignores.json> [--today YYYY-MM-DD]   every entry has a reason, an owner and a
                                                          future expiry; exit 1 and list the rest
  ignores.py trivy  <ignores.json> <target>               trivy ignore file (YAML) for one target
  ignores.py gitleaks <ignores.json> <repo>               gitleaks config (TOML) for one repo
  ignores.py sync-ci <ignores.json> <workspace>           write <repo>/.github/trivyignore.yaml
  ignores.py check-ci <ignores.json> <workspace>          fail if a repo's copy has drifted
  ignores.py pins   <workspace> <repo>...                 workflow rules: every `uses:` is a 40-hex
                                                          SHA, every workflow has top-level permissions
  ignores.py summary <json>...                            (used by scan.sh) counts from trivy/gitleaks JSON

Targets are repo names (invai-backend) or image names (image:backend). One ignore file for the whole
workspace; an expired entry stops being an ignore (trivy drops it itself) and fails `check`.
"""
import datetime
import json
import os
import re
import sys

REPO_OF_IMAGE = {
    "image:backend": "invai-backend",
    "image:imaging": "invai-imaging",
    "image:web": "invai-web",
    "image:floor": "invai-floor",
}
REQUIRED = ("tool", "id", "targets", "reason", "owner", "expires")


def load(path):
    with open(path) as fh:
        return json.load(fh)["ignores"]


def today_from(argv):
    if "--today" in argv:
        return datetime.date.fromisoformat(argv[argv.index("--today") + 1])
    return datetime.date.today()


def check(path, today):
    bad = []
    for i, e in enumerate(load(path)):
        label = "%s %s" % (e.get("tool", "?"), e.get("id", "?"))
        for k in REQUIRED:
            if not e.get(k):
                bad.append("%s: missing %s" % (label, k))
        if e.get("tool") not in ("trivy", "gitleaks"):
            bad.append("%s: tool must be trivy or gitleaks" % label)
        try:
            exp = datetime.date.fromisoformat(e.get("expires", ""))
        except ValueError:
            bad.append("%s: expires is not YYYY-MM-DD" % label)
            continue
        if exp < today:
            bad.append("%s: expired %s (owner %s): fix it or renew with a new reason" % (label, exp, e.get("owner")))
        if (exp - today).days > 190:
            bad.append("%s: expires %s, more than 190 days out" % (label, exp))
    for line in bad:
        print("IGNORE-FILE FAIL: " + line)
    print("ignores: %d entries, %d problems" % (len(load(path)), len(bad)))
    return 1 if bad else 0


def trivy_yaml(entries, target):
    out = ["# Generated from invai-infra/scan/ignores.json by scan/ignores.py. Do not edit.", "vulnerabilities:"]
    n = 0
    for e in entries:
        if e["tool"] == "trivy" and target in e["targets"]:
            n += 1
            out.append("  - id: %s" % e["id"])
            out.append('    statement: "%s (owner: %s)"' % (e["reason"].replace('"', "'"), e["owner"]))
            out.append("    expired_at: %s" % e["expires"])
    if n == 0:
        out = out[:1] + ["vulnerabilities: []"]
    return "\n".join(out) + "\n"


def gitleaks_toml(entries, repo):
    out = ["# Generated from invai-infra/scan/ignores.json by scan/ignores.py. Do not edit.", "[extend]", "useDefault = true", ""]
    for e in entries:
        if e["tool"] == "gitleaks" and repo in e["targets"]:
            out += [
                "[[allowlists]]",
                'description = "%s (owner: %s, expires %s)"' % (e["reason"].replace('"', "'"), e["owner"], e["expires"]),
                'targetRules = ["%s"]' % e["rule"],
                'condition = "AND"',
            ] + (["commits = [%s]" % ", ".join('"%s"' % c for c in e["commits"])] if e.get("commits") else []) + [
                "paths = ['''%s''']" % e["path_regex"],
                'regexTarget = "line"',
                "regexes = ['''%s''']" % e["line_regex"],
                "",
            ]
    return "\n".join(out)


def ci_targets(entries):
    """repo -> list of target names that CI in that repo scans."""
    m = {}
    for e in entries:
        for t in e["targets"]:
            repo = REPO_OF_IMAGE.get(t, t)
            m.setdefault(repo, set()).add(t)
    return m


def ci_file(entries, repo):
    """One trivy ignore file per repo: its lockfile entries plus its image entries (no overlap in ids)."""
    seen, merged = set(), []
    for t in sorted(ci_targets(entries).get(repo, [])):
        for e in entries:
            if e["tool"] == "trivy" and t in e["targets"] and e["id"] not in seen:
                seen.add(e["id"])
                merged.append(dict(e, targets=[repo]))
    return trivy_yaml(merged, repo)


def sync_ci(path, ws, write):
    entries = load(path)
    rc = 0
    for repo in sorted(d for d in os.listdir(ws) if re.match(r"invai-(contracts|ui|backend|web|floor|imaging|infra)$", d)):
        gh = os.path.join(ws, repo, ".github")
        if not os.path.isdir(gh):
            continue
        want = ci_file(entries, repo)
        dest = os.path.join(gh, "trivyignore.yaml")
        have = open(dest).read() if os.path.exists(dest) else None
        if write:
            if have != want:
                open(dest, "w").write(want)
                print("wrote " + dest)
        elif have != want:
            print("DRIFT: %s differs from scan/ignores.json (run: bash scripts/scan.sh sync)" % dest)
            rc = 1
    return rc


USES = re.compile(r"^\s*(?:-\s+)?uses:\s*(\S+)")
SHA = re.compile(r"@[0-9a-f]{40}(\s|$)")


def pins(ws, repos):
    bad, n_uses, n_files = [], 0, 0
    for repo in repos:
        wf = os.path.join(ws, repo, ".github", "workflows")
        if not os.path.isdir(wf):
            continue
        for name in sorted(os.listdir(wf)):
            if not name.endswith((".yml", ".yaml")):
                continue
            n_files += 1
            path = os.path.join(wf, name)
            text = open(path).read()
            if not re.search(r"^permissions:", text, re.M):
                bad.append("%s/.github/workflows/%s: no top-level permissions:" % (repo, name))
            for ln, line in enumerate(text.splitlines(), 1):
                m = USES.match(line)
                if not m:
                    continue
                ref = m.group(1)
                if ref.startswith("./"):
                    continue
                n_uses += 1
                if ref.startswith("docker://"):
                    ok = "@sha256:" in ref
                else:
                    ok = bool(SHA.search(line.strip() + " "))
                if not ok:
                    bad.append("%s/.github/workflows/%s:%d: %s is not pinned by SHA" % (repo, name, ln, ref))
    for b in bad:
        print("WORKFLOW-PIN FAIL: " + b)
    print("workflow pins: %d files, %d uses, %d problems" % (n_files, n_uses, len(bad)))
    return 1 if bad else 0


def summary(paths):
    """Print 'count high critical' per json file; trivy (Results[].Vulnerabilities) or gitleaks (list)."""
    total = 0
    for p in paths:
        d = json.load(open(p))
        if isinstance(d, list):
            c = len(d)
            print("%s findings=%d" % (os.path.basename(p), c))
            total += c
            continue
        hi = cr = sec = 0
        for r in d.get("Results") or []:
            for v in r.get("Vulnerabilities") or []:
                if v["Severity"] == "CRITICAL":
                    cr += 1
                else:
                    hi += 1
            sec += len(r.get("Secrets") or [])
        print("%s critical=%d high=%d secrets=%d" % (os.path.basename(p), cr, hi, sec))
        total += hi + cr + sec
    return 1 if total else 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "check":
        return check(argv[2], today_from(argv))
    if cmd == "trivy":
        sys.stdout.write(trivy_yaml(load(argv[2]), argv[3]))
        return 0
    if cmd == "gitleaks":
        sys.stdout.write(gitleaks_toml(load(argv[2]), argv[3]))
        return 0
    if cmd == "sync-ci":
        return sync_ci(argv[2], argv[3], True)
    if cmd == "check-ci":
        return sync_ci(argv[2], argv[3], False)
    if cmd == "pins":
        return pins(argv[2], argv[3:])
    if cmd == "summary":
        return summary(argv[2:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
