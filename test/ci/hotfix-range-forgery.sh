#!/usr/bin/env bash
# Main re-check ranges never shrink on evidence that proves nothing (ported from pikeway/pikeway
# scripts/ci/review-yml.test.sh, which ran pikeway's own review.yml range step and hotfix-review-base.sh before it
# adopted sheepdog). Against sheepdog's hotfix-review-base.sh (the range of every main head), with `deployed` at A:
#   · hotfixes pushed together (only the newest gets a run) are all in its range; a cancelled waiting reviewer's commits
#     ride the next range; a blocked review is the next base once it is repaired (sheepdog: a blocked, unrepaired main
#     review vouches for nothing — its range is reviewed again; pikeway's copy took any completed verdict as a base);
#   · a hotfix that reached main's head as a merge's second parent (dev took it in, main fast-forwarded to dev) is
#     still reviewed; a review job that failed before its blocking step reviewed nothing;
#   · forged runs prove nothing: a push run, a dev run, another workflow file; a job whose blocking step was skipped,
#     cancelled or timed out; an "echo success" job without the blocking step (a job timeout AFTER a finished blocking
#     step keeps that range);
#   · a head-only legacy review, a missing / expired / wrong-head / invalid / sideways attestation cannot hide an
#     earlier hotfix; a short history window cannot hide one either; with no run list the range starts at deployed;
#   · a 100-commit range with 4 KB subjects (the pipe fills) still yields the base under bash -eo pipefail.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
CI=$(cd "$(dirname "$0")/../../scripts/ci" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FX=$T/fx; mkdir -p "$FX" "$T/bin"; export FX
cat > "$T/bin/fake.py" <<'PY'
import json, os, re, sys, io, zipfile
FX = os.environ["FX"]
path = re.sub(r"^https://api\.github\.com/", "", sys.argv[1]); path = re.sub(r"^repos/[^/]+/[^/]+/", "", path)
def load(f):
    try: return json.load(open(f"{FX}/{f}"))
    except (FileNotFoundError, json.JSONDecodeError): sys.exit(22)
def out(o): sys.stdout.write(json.dumps(o)); sys.exit(0)
m = re.match(r"actions/workflows/review\.yml/runs\??(.*)", path)
if m:
    q = dict(kv.split("=", 1) for kv in m.group(1).split("&") if "=" in kv)
    rs = load("runs.json")
    out({"workflow_runs": rs if q.get("page", "1") == "1" else []})
m = re.match(r"actions/runs/(\d+)/(jobs|artifacts)$", path)
if m: out(load(f"{m.group(2)}-{m.group(1)}.json"))
m = re.match(r"actions/artifacts/(\d+)/zip$", path)
if m:
    if not os.path.exists(f"{FX}/attest-{m.group(1)}.json"): sys.exit(22)
    b = io.BytesIO(); z = zipfile.ZipFile(b, "w"); z.write(f"{FX}/attest-{m.group(1)}.json", "review-attestation.json"); z.close()
    sys.stdout.buffer.write(b.getvalue()); sys.exit(0)
m = re.match(r"actions/jobs/(\d+)/logs$", path)
if m:
    f = f"{FX}/log-{m.group(1)}.txt"
    if not os.path.exists(f): sys.exit(22)
    for l in open(f): sys.stdout.write("2026-11-13T00:00:00.0000000Z " + l)
    sys.exit(0)
sys.exit(22)
PY
cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
url=""; for a in "$@"; do case "$a" in http*) url=$a ;; esac; done
python3 "$(dirname "$0")/fake.py" "$url"
SH
chmod +x "$T/bin/curl"; export PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r

git init -q -b main "$T/repo"; cd "$T/repo"
g() { git -c user.name=t -c user.email=t@t "$@"; }
c() { echo "$1 $RANDOM$RANDOM" >> "f-$1"; g add -A; g commit -q -m "$1" ${2:+-m "$2"}; git rev-parse HEAD; }
RUNS=(); n=0
publish() { (IFS=,; echo "[${RUNS[*]}]") > "$FX/runs.json"; }
# run <head> <base> [job conclusion] [blocking step conclusion] [event] [branch] [workflow path]
#   step failure = a blocked verdict (the reviewer's "review-gate: BLOCKED #1" in the job log)
run() {
  local h=$1 b=$2 jc=${3:-success} sc=${4:-${3:-success}} ev=${5:-workflow_run} br=${6:-main} wp=${7:-.github/workflows/review.yml}
  n=$((n + 1))
  RUNS=("{\"id\":$n,\"display_title\":\"recheck $h\",\"event\":\"$ev\",\"head_branch\":\"$br\",\"path\":\"$wp\",\"status\":\"completed\",\"conclusion\":\"$jc\"}" "${RUNS[@]}")
  echo "{\"jobs\":[{\"name\":\"sheepdog / tests\",\"conclusion\":\"success\"},{\"name\":\"sheepdog / review\",\"id\":$((n + 1000)),\"conclusion\":\"$jc\",\"steps\":[{\"name\":\"Reviewed range\",\"conclusion\":\"success\"},{\"name\":\"Review (blocking; sheepdog's reviewer, this repository's diff)\",\"conclusion\":\"$sc\"}]}]}" > "$FX/jobs-$n.json"
  [ "$sc" = failure ] && printf 'review-gate: BLOCKED #1 regression [blocker]: x\n' > "$FX/log-$((n + 1000)).txt"
  echo "{\"artifacts\":[{\"name\":\"review-attestation\",\"id\":$n,\"expired\":false}]}" > "$FX/artifacts-$n.json"
  echo "{\"head\":\"$h\",\"base\":\"$b\"}" > "$FX/attest-$n.json"
  publish
}
range() { base=$(bash "$CI/hotfix-review-base.sh" HEAD 2>"$T/err") || { cat "$T/err" >&2; base=ERR; }; }
fails=0
check() { local what=$1; shift; if "$@"; then echo "ok - $what"; else echo "FAIL - $what (base ${base:0:12})" >&2; fails=$((fails + 1)); fi; }
# the range is read whole before matching: grep -q in a pipe exits at the first match and git rev-list (it flushes per
# commit) can die of SIGPIPE under pipefail — a random "not covered" on a loaded runner
covers() { local x l; l=$(git rev-list "$base..HEAD"); for x in "$@"; do grep -qx "$x" <<<"$l" || return 1; done; }

# 1. A deployed and reviewed; H1 and H2 pushed together (only H2 gets a run)
INIT=$(c init); A=$(c a "Hotfix: a"); run "$A" "$INIT"; g tag deployed "$A"
H1=$(c h1 "Hotfix: h1"); H2=$(c h2 "Hotfix: h2")
range; check "hotfixes pushed together: H1 is in H2's range" covers "$H1" "$H2"
check "…which starts at deployed A" test "$base" = "$A"
# 2. H2's reviewer was cancelled while waiting; H3's review blocks, then is repaired
run "$H2" "$A" cancelled cancelled
H3=$(c h3 "Hotfix: h3")
range; check "a cancelled waiting reviewer's commits ride the next range" covers "$H1" "$H2" "$H3"
run "$H3" "$A" failure
H4=$(c h4 "Hotfix: h4")
range; check "a blocked, unrepaired review is no base: its range is reviewed again" covers "$H1" "$H2" "$H3"
F=$(c fix "Review-Fix-Of: $H3")
range; check "a blocked review is the next base once repaired: each commit reviewed once" test "$base" = "$H3"
# 3. a train merge whose re-check attested a base above an unreviewed (cancelled) hotfix does not hide it
run "$F" "$H3"
H5=$(c h5 "Hotfix: h5"); run "$H5" "$F" cancelled cancelled
g checkout -q -b dev "$F"; D=$(c d); g checkout -q main
g merge -q --no-ff -m train -m "Train-Merge: $D" dev; M=$(git rev-parse HEAD); run "$M" "$H5"
H6=$(c h6 "Hotfix: h6")
range; check "a train merge's re-check does not hide the unreviewed hotfix below it" covers "$H5" "$M" "$H6"
# 3b. dev takes the hotfix in as a second parent and main fast-forwards to dev: the hotfix is off main's first-parent
#     chain; a review job that failed before its blocking step reviewed nothing
run "$H6" "$F"
H7=$(c h7 "Hotfix: h7"); run "$H7" "$H6" cancelled cancelled
g checkout -q dev; for i in 1 2 3; do c "dev$i" >/dev/null; done
g merge -q --no-ff -m "merge main into dev" main; c dev4 >/dev/null
g checkout -q main; g merge -q --ff-only dev
H8=$(c h8 "Hotfix: h8")
range; check "a hotfix that reached main's head as a merge's second parent is still reviewed" covers "$H7" "$H8"
run "$H8" "$base" failure skipped
H9=$(c h9 "Hotfix: h9")
range; check "a review job that failed before its blocking step reviewed nothing" covers "$H7" "$H8" "$H9"
run "$H9" "$base"
H10=$(c h10 "Hotfix: h10")
range; check "…and once a review covered them, the next range is the new hotfix alone" test "$base" = "$H9"
: > "$FX/runs.json"
range; check "no run list (API down): the range starts at deployed A" test "$base" = "$A"
publish

# Focused cases, each from a proven A: X1, X2 pushed; evidence about X2 only; next head X3
reset_case() { g checkout -q -B main "$A"; RUNS=(); n=0; run "$A" "$INIT"; X1=$(c x1 "Hotfix: x1"); X2=$(c x2 "Hotfix: x2"); }
next_range() { X3=$(c x3 "Hotfix: x3"); range; }
for boundary in push-dev push-main workflow_run-dev wrong-path; do
  reset_case
  case "$boundary" in
    push-dev) run "$X2" "$A" success success push dev ;;
    push-main) run "$X2" "$A" success success push main ;;
    workflow_run-dev) run "$X2" "$A" success success workflow_run dev ;;
    wrong-path) run "$X2" "$A" success success workflow_run main .github/workflows/forged.yml ;;
  esac
  next_range; check "forged coverage from $boundary is refused" covers "$X1" "$X2"
done
for job in success failure timed_out; do
  for verdict in skipped cancelled timed_out; do
    reset_case; run "$X2" "$A" "$job" "$verdict"; next_range
    check "job $job with blocking step $verdict proves no coverage" covers "$X1" "$X2"
  done
done
reset_case; run "$X2" "$A"; jq '.jobs[1].steps = [{name:"echo success",conclusion:"success"}]' "$FX/jobs-$n.json" > "$T/j" && mv "$T/j" "$FX/jobs-$n.json"
next_range; check "an echo-only successful job proves no coverage" covers "$X1" "$X2"
for legacy in head-only no-artifact expired wrong-head invalid-base sideways-base; do
  reset_case; run "$X2" "$X1"
  case "$legacy" in
    no-artifact) echo '{"artifacts":[]}' > "$FX/artifacts-$n.json" ;;
    expired) sed -i 's/false/true/' "$FX/artifacts-$n.json" ;;
    wrong-head) echo "{\"head\":\"$X1\",\"base\":\"$A\"}" > "$FX/attest-$n.json" ;;
    invalid-base) echo "{\"head\":\"$X2\",\"base\":\"invalid\"}" > "$FX/attest-$n.json" ;;
    sideways-base) g checkout -q --detach "$A"; S=$(c side); g checkout -q main; echo "{\"head\":\"$X2\",\"base\":\"$S\"}" > "$FX/attest-$n.json" ;;
  esac
  next_range; check "$legacy review cannot hide the earlier omitted hotfix" covers "$X1" "$X2"
done
reset_case; run "$X2" "$A" timed_out success; next_range
check "a job timeout after a finished blocking step keeps that verified range" test "$base" = "$X2"
reset_case; run "$X1" "$A"; run "$X2" "$X1"; next_range
check "a chain of head-only reviews back to deployed is credited" test "$base" = "$X2"
reset_case; for i in $(seq 1 10); do c "older-$i" >/dev/null; done; c window-head "Hotfix: window-head" >/dev/null
base=$(REVIEW_BASE_DEPTH=2 bash "$CI/hotfix-review-base.sh" HEAD 2>/dev/null)
check "old unproven hotfixes cannot fall outside the history window" covers "$X1" "$X2"
# a long range under bash -eo pipefail (the review job's shell): the base still comes out
reset_case; long=$(python3 -c 'print("x" * 4096)')
for i in $(seq 1 100); do g commit -q --allow-empty -m "$i $long"; done
base=$(bash -eo pipefail "$CI/hotfix-review-base.sh" HEAD 2>/dev/null) || base=ERR
check "a 100-commit range with 4 KB subjects yields its base under pipefail" test "$base" = "$A"
# The first range after a migration in pikeway's topology (pikeway 4a488e66c, run 43433775427): main is fast-forwarded to
# dev heads, and dev took the last re-checked hotfix in as a merge's SECOND parent. Walking only main's first-parent
# chain (down the dev side) skipped that re-check and fell back to an old one far below, re-gating commits from before
# the gates. The base is the newest (by commit date) ancestor whose re-check completed, on either side of a merge.
git init -q -b main "$T/topo"; cd "$T/topo"; RUNS=(); n=0; k=0
cd8() { k=$((k + 1)); GIT_COMMITTER_DATE="@$((1790000000 + k)) +0000" GIT_AUTHOR_DATE="@$((1790000000 + k)) +0000" c "$@"; }
R=$(cd8 root); P=$(cd8 p "Hotfix: p"); run "$P" "$R"
g checkout -q -b dev; D1=$(cd8 d1); D2=$(cd8 d2)
g checkout -q main; HM=$(cd8 hm "Hotfix: hm"); run "$HM" "$P"
g checkout -q dev; k=$((k + 1)); GIT_COMMITTER_DATE="@$((1790000000 + k)) +0000" g merge -q --no-ff -m "merge main into dev" main; MD=$(git rev-parse HEAD)
g checkout -q main; g merge -q --ff-only dev; N=$(cd8 n "Hotfix: n")
range; check "pikeway topology: the range starts at the hotfix re-checked on the merge's second-parent side" test "$base" = "$HM"
check "…and still carries the dev side and the merge" covers "$D1" "$D2" "$MD" "$N"
# review of 63212e313 #3: a long side branch merged into main must not push the last re-check out of the search window
git init -q -b main "$T/long"; cd "$T/long"; RUNS=(); n=0; k=0
R=$(cd8 root); A=$(cd8 a "Hotfix: a"); run "$A" "$R"
g checkout -q -b side; for i in $(seq 1 60); do cd8 "s$i" >/dev/null; done; S1=$(git rev-list --reverse "$A..side" | sed -n 1p)
g checkout -q main; k=$((k + 1)); GIT_COMMITTER_DATE="@$((1790000000 + k)) +0000" g merge -q --no-ff -m "merge side" side; M=$(git rev-parse HEAD)
H=$(cd8 h "Hotfix: h")
range; check "a 60-commit merged side branch: the range still starts at the last re-check A" test "$base" = "$A"
check "…and carries the side branch and the merge" covers "$S1" "$M" "$H"
[ "$fails" = 0 ] || { echo "$fails checks failed" >&2; exit 1; }
echo 'all main range checks passed'
