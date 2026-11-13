#!/usr/bin/env bash
# Main re-check ranges carry untagged commits (ported from pikeway/pikeway scripts/ci/hotfix-coverage.test.sh, which
# tested pikeway's own hotfix-review-base.sh before it adopted sheepdog). Against sheepdog's hotfix-review-base.sh and
# review-passed.sh, with the tag `deployed` (contract (f): the host autodeploy keeps it at production's sha) at A:
#   · an untagged commit pushed together with a Hotfix: head is in the head's range;
#   · a legacy head-only review (attested U..H, missing U) cannot hide U: its link does not reach deployed, so the
#     next range starts below U;
#   · a proven cumulative range retires everything below it; a completed review of an untagged head is a link;
#   · a side branch merged into main (its commits and the merge itself) rides the next range; a proven merge range
#     is credited; with no readable runs the range starts at deployed.
# Differences from pikeway's copy (sheepdog's contract): bases are first-parent ancestors with a completed, linked
# review; with no evidence the range starts at the deployed sha (pikeway's copy started at the root commit).
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
CI=$(cd "$(dirname "$0")/../../scripts/ci" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FX=$T/fx; mkdir -p "$FX" "$T/bin"; export FX
cat > "$T/bin/fake.py" <<'PY'
import json, os, re, sys, io, zipfile
FX = os.environ["FX"]
path = re.sub(r"^https://api\.github\.com/", "", sys.argv[1]); path = re.sub(r"^repos/[^/]+/[^/]+/", "", path)
def out(o): sys.stdout.write(json.dumps(o)); sys.exit(0)
m = re.match(r"actions/workflows/review\.yml/runs\??(.*)", path)
if m:
    q = dict(kv.split("=", 1) for kv in m.group(1).split("&") if "=" in kv)
    try: rs = json.load(open(f"{FX}/runs.json"))
    except (FileNotFoundError, json.JSONDecodeError): sys.exit(22)
    rs = [dict(r, event="workflow_run", head_branch="main", path=".github/workflows/review.yml", status="completed", conclusion="success") for r in rs]
    out({"workflow_runs": rs if q.get("page", "1") == "1" else []})
m = re.match(r"actions/runs/(\d+)/jobs$", path)
if m: out({"jobs": [{"name": "sheepdog / tests", "conclusion": "success"}, {"name": "sheepdog / review", "id": 1, "conclusion": "success",
          "steps": [{"name": "Review (blocking; sheepdog's reviewer, this repository's diff)", "conclusion": "success"}]}]})
m = re.match(r"actions/runs/(\d+)/artifacts$", path)
if m: out({"artifacts": [{"name": "review-attestation", "id": int(m.group(1)), "expired": False}]})
m = re.match(r"actions/artifacts/(\d+)/zip$", path)
if m:
    b = io.BytesIO(); z = zipfile.ZipFile(b, "w"); z.write(f"{FX}/attest-{m.group(1)}.json", "review-attestation.json"); z.close()
    sys.stdout.buffer.write(b.getvalue()); sys.exit(0)
sys.exit(22)
PY
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1; shift; p=""; q=""
while [ $# -gt 0 ]; do case "$1" in -q) q=$2; shift 2 ;; -*) shift ;; *) [ -z "$p" ] && p=$1; shift ;; esac; done
case "$p" in */zip) python3 "$(dirname "$0")/fake.py" "$p"; exit ;; esac
o=$(python3 "$(dirname "$0")/fake.py" "$p") || exit 1
if [ -n "$q" ]; then jq -r "$q" <<<"$o"; else printf '%s\n' "$o"; fi
SH
cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
url=""; for a in "$@"; do case "$a" in http*) url=$a ;; esac; done
python3 "$(dirname "$0")/fake.py" "$url"
SH
chmod +x "$T/bin/gh" "$T/bin/curl"; export PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r

git init -q -b main "$T/repo"; cd "$T/repo"
g() { git -c user.name=t -c user.email=t@t "$@"; }
c() { echo "$1" > "$1"; g add -A; g commit -qm "$1" ${2:+-m "$2"}; git rev-parse HEAD; }
RUNS=(); n=0
review() { # review <attested base> <head>: a completed, trusted "recheck <head>" run with its attestation
  n=$((n + 1)); RUNS=("{\"id\":$n,\"display_title\":\"recheck $2\"}" "${RUNS[@]}")
  (IFS=,; echo "[${RUNS[*]}]") > "$FX/runs.json"
  echo "{\"head\":\"$2\",\"base\":\"$1\"}" > "$FX/attest-$n.json"
}
range() { bash "$CI/hotfix-review-base.sh" HEAD 2>/dev/null; }
fails=0
check() { local what=$1; shift; if "$@"; then echo "ok - $what"; else echo "FAIL - $what" >&2; fails=$((fails + 1)); fi; }
covers() { git rev-list "$base..HEAD" | grep -qx "$1"; }

ROOT_SHA=$(c root); A=$(c a 'Hotfix: a'); review "$ROOT_SHA" "$A"; g tag deployed "$A"
U=$(c untagged-prerequisite); H=$(c hotfix 'Hotfix: hotfix')
base=$(range)
check 'untagged prerequisite in the same push is reviewed' covers "$U"
check 'base is the proven reviewed/deployed A' test "$base" = "$A"
saved=("${RUNS[@]}"); review "$base" "$H"
check 'the deployment gate accepts the selected range against deployed A' bash "$CI/review-passed.sh" "$H" o/r "$A"
RUNS=("${saved[@]}"); (IFS=,; echo "[${RUNS[*]}]") > "$FX/runs.json"
review "$U" "$H"   # legacy review missed U: a later range must recover it
N=$(c next 'Hotfix: next')
base=$(range)
check 'legacy head-only review cannot permanently hide an untagged prerequisite' covers "$U"
check 'recovery range reaches deployed A' test "$base" = "$A"
review "$A" "$N"
c next-after-recovery 'Hotfix: next-after-recovery' >/dev/null
base=$(range)
check 'a proven cumulative range retires all incoming commits' test "$base" = "$N"
# Completed review heads need no Hotfix trailer to be links of the chain.
g checkout -q -B main "$A"
RUNS=(); n=0; review "$ROOT_SHA" "$A"; review "$A" "$U"; review "$U" "$H"
g reset -q --hard "$H"
c after-untagged-proof 'Hotfix: after-untagged-proof' >/dev/null
base=$(range)
check 'a completed review of an untagged head is a link' test "$base" = "$H"
# Unknown untagged side commits and the merge itself also enter the range.
g checkout -q -B side "$A"; SIDE=$(c side-prerequisite)
g checkout -q main; g reset -q --hard "$A"
g merge -q --no-ff -m merge-side side; MERGE=$(git rev-parse HEAD)
c after-merge 'Hotfix: after-merge' >/dev/null
base=$(range)
check 'untagged second-parent prerequisite is reviewed' covers "$SIDE"
check 'untagged merge is reviewed' covers "$MERGE"
check 'merge range reaches deployed A' test "$base" = "$A"
review "$A" "$MERGE"
base=$(range)
check 'proven untagged merge range is credited' test "$base" = "$MERGE"
rm -f "$FX/runs.json"
base=$(range)
check 'API outage carries untagged prerequisites too' covers "$SIDE"
check 'API outage starts at deployed A' test "$base" = "$A"
[ "$fails" = 0 ] || { echo "$fails checks failed" >&2; exit 1; }
echo 'all hotfix coverage checks passed'
