#!/usr/bin/env bash
# The workflows' safety wiring (static; needs python3 + PyYAML): every action pinned by a full commit sha, no
# `secrets: inherit`, no persisted checkout credentials, the reusable review workflow reads its own pinned sha from
# GitHub (never from an input), the tests job holds only a read token, and sheepdog's own CI never runs on a
# self-hosted runner and never touches secrets.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
cd "$(dirname "$0")/../.."
python3 - .github/workflows/*.yml examples/.github/workflows/*.yml <<'PY'
import re, sys, yaml
bad = []
def walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values(): yield from walk(v)
    elif isinstance(o, list):
        for v in o: yield from walk(v)
docs = {}
for f in sys.argv[1:]:
    text = open(f).read()
    docs[f] = yaml.safe_load(text)
    if re.search(r"secrets:\s*inherit", text): bad.append(f"{f}: secrets: inherit")
    for node in walk(docs[f]):
        u = node.get("uses")
        if isinstance(u, str) and not u.startswith("./"):
            if not re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", u): bad.append(f"{f}: {u} is not pinned by a full commit sha")
        if isinstance(u, str) and u.startswith("actions/checkout@") and (node.get("with") or {}).get("persist-credentials") is not False:
            bad.append(f"{f}: a checkout persists credentials")

rv = docs[".github/workflows/review.yml"]
on = rv.get(True, rv.get("on"))
if list(on) != ["workflow_call"]: bad.append("review.yml: must be workflow_call only")
if rv.get("permissions") != {}: bad.append("review.yml: top-level permissions must be {}")
jobs = rv["jobs"]
t = jobs["tests"]
if t.get("permissions") != {"contents": "read"}: bad.append("review.yml tests: only contents: read")
if "secrets." in yaml.safe_dump(t): bad.append("review.yml tests: the job that runs candidate code must not see secrets")
if "inputs.tests-runs-on-main" not in t["runs-on"] or "head_branch == inputs.main-branch" not in t["runs-on"]: bad.append("review.yml tests: main heads must use tests-runs-on-main")
steps = jobs["review"]["steps"]
names = [s.get("name", "") for s in steps]
pin = names.index("Pinned sheepdog sha") if "Pinned sheepdog sha" in names else -1
co = next((i for i, s in enumerate(steps) if (s.get("with") or {}).get("path") == ".sheepdog"), -1)
if pin < 0 or co < 0 or pin > co: bad.append("review.yml review: the pinned sha must be resolved before the sheepdog checkout")
elif steps[co]["with"].get("ref") != "${{ env.SHEEPDOG_SHA }}": bad.append("review.yml review: sheepdog is checked out at the resolved sha")
elif "referenced_workflows" not in steps[pin]["run"] or '[ "$ref" = "$sha" ]' not in steps[pin]["run"]: bad.append("review.yml review: the pin must come from referenced_workflows and be a full sha")
for s in steps:
    run = s.get("run", "")
    if "${{" in run: bad.append(f"review.yml step {s.get('name')}: expression inside run (use env)")
for f, d in docs.items():
    if not f.endswith("/ci.yml") or not f.startswith(".github"): continue
    for name, j in d["jobs"].items():
        ro = j.get("runs-on", "")
        if "self-hosted" in str(ro): bad.append(f"{f} {name}: sheepdog's own CI never runs on self-hosted runners")
        if "secrets." in yaml.safe_dump(j).replace("secrets.GITHUB_TOKEN", ""): bad.append(f"{f} {name}: no secrets in sheepdog's own CI")
for b in bad: print("FAIL:", b)
sys.exit(1 if bad else 0)
PY
echo 'workflow wiring: pinned actions, no inherited secrets, no persisted credentials, pinned reviewer, read-only tests'
