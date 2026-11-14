#!/usr/bin/env bash
# Pre-existing MAIN findings in a dev review (supervisor 11-14). The real case: the dev review of 0cd95ca42 (run
# 43577623889, its log in lib/review-0cd95ca42.log with the shas as placeholders) blocked on FINDING #1/#2
# commit=341cca4e9 — a commit already on main that came into the dev range through a main→dev merge — plus #3, the dev
# head's own. The dispatcher woke a dev fixer for all of it, counted the round and sent fixfailed.
#   (a) blocked ONLY by main-culprit findings → review-passed.sh approves (kind review), the dispatcher's head loop and
#       train land it through merge-branch.sh; no dev_blocked / fixer; the findings are recorded as pre-existing
#   (b) mixed (#1/#2 main + #3 dev) → still blocked; only #3 is routed on dev; #1/#2 recorded
#   (c) culprit not on main / not on the attested main / "-" / abbreviated / no FINDING line → blocked as before
#   (d) review-passed.sh and the dispatcher agree in every case; plus: a failed tests job, a failed gate step, a re-check
#       title, injected lines before the gate's own "reviewing" line, and REVIEW_MAIN_FINDINGS=0 never approve.
set -uo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
cd "$(dirname "$0")/../.."
ROOT=$(pwd); D=$ROOT/scripts/ci/review-dispatch.sh; FIXTURE=$ROOT/test/ci/lib/review-0cd95ca42.log
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
FX=$T/fx; mkdir -p "$FX" "$T/bin"; export FX

# ── a fake GitHub: `gh api <path> [-q f]` and `gh run list … --json …` (the dispatcher's listing), from $FX fixtures ──
cat > "$T/bin/fakegh.py" <<'PY'
import json, os, re, sys, io, zipfile
FX = os.environ["FX"]
def runs():
    try: return json.load(open(f"{FX}/runs.json"))
    except FileNotFoundError: return []
def answer(path):
    path = re.sub(r"^https://api\.github\.com/", "", path); path = re.sub(r"^repos/[^/]+/[^/]+/", "", path)
    m = re.match(r"actions/workflows/[^/]+/runs\??(.*)", path)
    if m:
        q = dict(kv.split("=", 1) for kv in m.group(1).split("&") if "=" in kv)
        rs = [dict(r, event="workflow_run", head_branch="main", path=".github/workflows/review.yml") for r in runs()]
        st = q.get("status")
        if st == "completed": rs = [r for r in rs if r["status"] == "completed"]
        elif st: rs = [r for r in rs if r.get("conclusion") == st]
        n = int(q.get("per_page", "30")); pg = int(q.get("page", "1"))
        return {"workflow_runs": rs[(pg - 1) * n:pg * n]}
    m = re.match(r"actions/runs/(\d+)/jobs$", path)
    if m: return json.load(open(f"{FX}/jobs-{m.group(1)}.json"))
    m = re.match(r"actions/runs/(\d+)$", path)
    if m: return [r for r in runs() if str(r["id"]) == m.group(1)][0]
    m = re.match(r"actions/runs/(\d+)/artifacts$", path)
    if m: return {"artifacts": [{"name": "review-attestation", "id": int(m.group(1))}] if os.path.exists(f"{FX}/attest-{m.group(1)}.json") else []}
    m = re.match(r"actions/artifacts/(\d+)/zip$", path)
    if m:
        b = io.BytesIO(); z = zipfile.ZipFile(b, "w"); z.write(f"{FX}/attest-{m.group(1)}.json", "review-attestation.json"); z.close()
        sys.stdout.buffer.write(b.getvalue()); sys.exit(0)
    m = re.match(r"actions/jobs/(\d+)/logs$", path)
    if m:
        f = f"{FX}/log-{m.group(1)}.txt"
        if not os.path.exists(f): sys.exit(22)
        sys.stdout.write(open(f).read()); sys.exit(0)
    sys.exit(22)
if sys.argv[1] == "list":   # gh run list --json …: the dispatcher's listing fields
    print(json.dumps([{"databaseId": r["id"], "displayTitle": r["display_title"], "status": r["status"],
                       "conclusion": r.get("conclusion", ""), "event": "workflow_run", "headBranch": "main",
                       "headSha": "0" * 40} for r in runs()]))
    sys.exit(0)
r = answer(sys.argv[1]); sys.stdout.write(json.dumps(r))
PY
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FX/calls"
if [ "$1 $2" = "run list" ]; then
  q=""; while [ $# -gt 0 ]; do case "$1" in -q) q=$2; shift 2 ;; *) shift ;; esac; done
  out=$(python3 "$(dirname "$0")/fakegh.py" list); if [ -n "$q" ]; then jq -r "$q" <<<"$out"; else printf '%s\n' "$out"; fi; exit 0
fi
[ "$1" = run ] && exit 0      # run cancel / rerun: recorded in calls
[ "$1" = api ] || exit 1; shift; p=""; q=""
while [ $# -gt 0 ]; do case "$1" in -q) q=$2; shift 2 ;; --paginate) shift ;; -*) shift ;; *) [ -z "$p" ] && p=$1; shift ;; esac; done
case "$p" in */zip|*/logs) python3 "$(dirname "$0")/fakegh.py" "$p"; exit ;; esac
out=$(python3 "$(dirname "$0")/fakegh.py" "$p") || exit 1
if [ -n "$q" ]; then jq -r "$q" <<<"$out"; else printf '%s\n' "$out"; fi
SH
chmod +x "$T/bin/gh" "$T/bin/fakegh.py"; export PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r MAIN_BRANCH=main REVIEW_DEFAULT_BRANCH=main

# ── history: main B0 → C (the culprit, like 341cca4e9); dev D1 (dev work) → MX (merge main into dev) → H (the reviewed
#    head, like 0cd95ca42) ──
git init -q --bare "$T/remote.git"; SRC=$T/src; git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
c() { mkdir -p "$SRC/$(dirname "$1")"; echo "$RANDOM$RANDOM" >> "$SRC/$1"; g add "$1"; g commit -q -m "$2" -m "Loop: adhoc/x
Thread: mcp:${3:-11111111-1111-1111-1111-111111111111}"; g rev-parse HEAD; }
B0=$(c base.txt base)
g checkout -q -b dev; D1=$(c scripts/ci/review-dispatch.sh "dev work" 22222222-2222-2222-2222-222222222222)
g checkout -q main; C=$(c scripts/ci/dev-review-base.sh "fix(review): main's culprit (like 341cca4e9)")
g push -q origin main
g checkout -q dev; g merge -q --no-ff main -m "merge main into dev"; MX=$(g rev-parse HEAD)
H=$(c scripts/ci/review-dispatch.sh "fix(dispatch): the reviewed dev head (like 0cd95ca42)" 22222222-2222-2222-2222-222222222222)
g push -q origin dev; g fetch -q origin
MAINSHA=$(g rev-parse origin/main)

# ── fixtures ──
# fixture_log <file> <culprit for #1/#2> <keep #3: 0|1> [<culprit for #3>] → the real 0cd95ca42 log on this history
fixture_log() {
  local out=$1 cul=$2 keep3=$3 c3=${4:-$H}
  sed -e "s/@MAIN_CULPRIT@/$cul/g; s/@HEAD@/$H/g; s/@BASE@/$B0/g; s/@MAIN@/$MAINSHA/g; s/@BASE8@/${B0:0:8}/; s/@HEAD8@/${H:0:8}/" "$FIXTURE" \
    | sed -e "s/commit=$H /commit=$c3 /" > "$out"
  if [ "$keep3" = 0 ]; then
    awk '/review-gate: (FINDING|BLOCKED) #3 /{skip = 1; next} skip && /^[^ ]+ evidence:/{skip = 0; next} {skip = 0; print}' "$out" > "$out.t" && mv "$out.t" "$out"
  fi
}
RID=500; JID=1500
STEPS_OK='{"name":"Reviewed range","conclusion":"success"},{"name":"Commit gates (sheepdog'"'"'s gates + the repository'"'"'s extra gate, the branch'"'"'s commits)","conclusion":"success"},{"name":"Attestation (reviewed range)","conclusion":"success"},{"name":"Review (blocking; sheepdog'"'"'s reviewer, this repository'"'"'s diff)","conclusion":"failure"},{"name":"Run actions/upload-artifact","conclusion":"success"}'
# scenario <title> <tests concl> <steps json> <attested main> → one completed, failed review run of H with the log in $T/log
scenario() {
  rm -f "$FX"/*.json "$FX"/log-* "$FX/calls"
  echo "{\"jobs\":[{\"name\":\"sheepdog / tests\",\"conclusion\":\"$2\"},{\"name\":\"sheepdog / review\",\"id\":$JID,\"conclusion\":\"failure\",\"steps\":[$3]}]}" > "$FX/jobs-$RID.json"
  cp "$T/log" "$FX/log-$JID.txt"
  echo "{\"head\":\"$H\",\"base\":\"$B0\",\"kind\":\"review\",\"main\":\"$4\"}" > "$FX/attest-$RID.json"
  echo "[{\"id\":$RID,\"display_title\":\"$1\",\"status\":\"completed\",\"conclusion\":\"failure\"}]" > "$FX/runs.json"
}
RP() { (cd "$SRC" && bash "$ROOT/scripts/ci/review-passed.sh" "$H" o/r >/dev/null 2>"$T/rp.err"); }

# ── the dispatcher's head loop and merge train, as in review-dispatch-merge-only.sh: the real code, stubbed effects ──
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }
STATE=$T/state MAIN=main DEV=dev TRUSTED=$T/trusted WORK=$T/work OUTBOX=$T/state/outbox CI_SCRIPTS=$ROOT/scripts/ci
DEV_REVERT_AFTER_SEC=3600 DEV_REVERT_WARN_SEC=900 key_prefix="" SUPERVISOR_THREAD=sup DISPATCH_THREAD=disp
mkdir -p "$STATE/sent" "$OUTBOX"; LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
git -C "$SRC" worktree add -q --detach "$TRUSTED" origin/main
eval "$(sed -n '/^review_list() {/,/^}/p; /^dev_round_noop() {/,/^}/p; /^dev_merge_only() {/,/^}/p; /^review_infra_reason() {/,/^}/p; /^run_verdict() {/,/^}/p; /^dev_verdict_run() {/,/^}/p; /^named_files() {/p; /^findings_cap() {/,/^}/p; /^findings() {/,/^}/p; /^notes_of() {/,/^}/p; /^findings_subset() {/,/^}/p; /^main_culprits_api() /p; /^main_culprit_hint() {/,/^}/p; /^dev_split_main() {/,/^}/p; /^thread_of() /p; /^range_threads() {/,/^}/p' "$D")"
source "$ROOT/scripts/ci/review-main-culprits.sh"
source "$ROOT/scripts/ci/review-machinery.sh"
for f in review_list findings findings_subset main_culprit_hint dev_split_main main_culprits_api review_main_culprits dev_verdict_run; do
  declare -F "$f" >/dev/null || fail "helper $f not extracted"
done
fixer_receipt_thread() { :; }
dev_blocked() { echo "dev_blocked $1" >> "$T/calls"; printf '%s\n' "$2" > "$T/routed"; printf '%s\n' "${6:-}" > "$T/routed-all"; }
wake_fixer() { echo "wake_fixer $1 $2" >> "$T/calls"; }
notify() { echo "notify $2" >> "$T/calls"; }; notify_best_effort() { notify "$@"; }; notify_attributed() { echo "notify_attributed $2" >> "$T/calls"; }
culprit_threads() { :; }; attribution() { :; }; fixer_phrase() { :; }; own_findings() { :; }; revert_after_for() { echo 3600; }
dev_infra() { echo "dev_infra $1" >> "$T/calls"; }
loop=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('\nnow=$(date +%s)\nfor ref in ') + 1
print(s[a:s.index('\ndone\n', a) + 6])
PY
)
train=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('\nmerged_one=0\n') + 1
print(s[a:s.index('\n# ── review-fix landing', a)])
PY
)
[ -n "$loop" ] && [ -n "$train" ] || fail "could not extract the head loop / the train"
reset_dev() { g push -q -f origin "$MAINSHA:refs/heads/main" "$H:refs/heads/dev"; g fetch -q origin; git -C "$TRUSTED" checkout -q --detach origin/main
  rm -f "$T/calls" "$T/routed" "$LOG" "$STATE/open-findings.log" "$STATE/sent/"* "$STATE/dev.blocked_since"*; }
run_head_loop() { reset_dev; merged_one=0; DRY=""; ( cd "$ROOT" && eval "$loop" ) || fail "head loop failed"; g fetch -q origin; }
run_train() { reset_dev; DRY=""; ( cd "$ROOT" && eval "$train" ) || fail "train failed"; g fetch -q origin; }
landed() { [ "$(g rev-parse origin/main)" = "$H" ]; }
routed_nums() { sed -nE 's/^review-gate: BLOCKED #([0-9]+) .*/\1/p' "$T/routed" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# ── (a) the real 0cd95ca42 log without its own #3: blocked only by #1/#2, culprit on main ──
fixture_log "$T/log" "$C" 0
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
RP || fail "(a) review-passed.sh refused a dev review blocked only by main-culprit findings: $(cat "$T/rp.err")"
grep -q "blocked only by finding(s) whose culprit is on main (#1 ${C:0:9} #2 ${C:0:9}" "$T/rp.err" || fail "(a) review-passed.sh did not say why: $(cat "$T/rp.err")"
kf=$T/kind; (cd "$SRC" && REVIEW_KIND_OUT=$kf bash "$ROOT/scripts/ci/review-passed.sh" "$H" o/r >/dev/null 2>&1); [ "$(cat "$kf")" = review ] || fail "(a) approval kind is not review"
run_head_loop
landed || fail "(a) the head loop did not land $H: $(cat "$LOG" 2>/dev/null)"
! grep -qE '^(dev_blocked|wake_fixer|notify)' "$T/calls" 2>/dev/null || fail "(a) a dev fixer / notice for main's findings: $(cat "$T/calls")"
grep -q "finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" || fail "(a) main findings not recorded as pre-existing"
[ "$(grep -c '^review-gate: BLOCKED #[12] ' "$STATE/open-findings.log")" = 2 ] || fail "(a) the known-open feed lacks the BLOCKED lines"
! grep -q "BLOCKED #3" "$STATE/open-findings.log" || fail "(a) recorded a finding that is not main's"
test ! -e "$STATE/dev.blocked_since" || fail "(a) a dev block clock started for main's findings"
grep -q "MERGED dev" "$LOG" || fail "(a) no MERGED log line"
! grep -q "run cancel" "$FX/calls" 2>/dev/null || fail "(a) cancelled a run"
run_train
landed || fail "(a) the train did not land $H: $(cat "$LOG" 2>/dev/null)"
! grep -qE '^(dev_blocked|wake_fixer|notify)' "$T/calls" 2>/dev/null || fail "(a) the train's blocked path routed main's findings: $(cat "$T/calls")"
echo "ok - (a) blocked only by main-culprit findings: approved, landed (head loop + train), no fixer, recorded as pre-existing"

# the known-open feed of the next review (review.yml's "Known open findings" step) carries them
grep -E '^review-gate: BLOCKED' "$STATE/open-findings.log" | sed -E 's/^review-gate: BLOCKED (#[0-9]+ )?//' | grep -q '^regression \[should, security\]: The path-scoped preservation proof' \
  || fail "(a) known-open feed"

# ── (b) the real log as it was: #1/#2 main + #3 the head's own ──
fixture_log "$T/log" "$C" 1
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
! RP || fail "(b) review-passed.sh approved a review with a dev finding"
run_head_loop
! landed || fail "(b) landed with a dev finding"
grep -q "^dev_blocked $H" "$T/calls" || fail "(b) the dev finding was not routed"
[ "$(routed_nums)" = 3 ] || fail "(b) routed findings '$(routed_nums)', want only 3"
grep -q "commit=$H" "$T/routed" && ! grep -q "commit=$C" "$T/routed" || fail "(b) routed text carries main's findings"
grep -q "finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" || fail "(b) main findings not recorded"
run_train
grep -q "^dev_blocked $H" "$T/calls" || fail "(b) the train's blocked path did not route #3"
[ "$(routed_nums)" = 3 ] || fail "(b) train routed '$(routed_nums)', want 3"
! landed || fail "(b) the train landed a dev finding"
echo "ok - (b) mixed: still blocked, only the dev finding (#3) routed, #1/#2 recorded"

# ── (c) the culprit is NOT on main: the dev commit D1 ──
fixture_log "$T/log" "$D1" 0
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
! RP || fail "(c) review-passed.sh approved a dev culprit"
run_head_loop
! landed || fail "(c) landed"
[ "$(routed_nums)" = "1 2" ] || fail "(c) routed '$(routed_nums)', want 1 2"
test ! -e "$STATE/open-findings.log" || fail "(c) recorded a dev finding as main's"
echo "ok - (c) culprit off main: blocked and routed as before"

# (c2) the culprit is on main now, but not on the main the review recorded
fixture_log "$T/log" "$C" 0
scenario "review $H" success "$STEPS_OK" "$B0"
! RP || fail "(c2) approved against main as it is now, not as the review recorded it"
run_head_loop; ! landed || fail "(c2) landed"; [ "$(routed_nums)" = "1 2" ] || fail "(c2) routed '$(routed_nums)'"
# (c3) one finding without a culprit ("-") / an abbreviated one / no FINDING line at all
for variant in dash abbrev nofinding; do
  fixture_log "$T/log" "$C" 0
  case $variant in
    dash) sed -i -E "s/FINDING #2 route=author commit=$C/FINDING #2 route=author commit=-/" "$T/log" ;;
    abbrev) sed -i -E "s/FINDING #2 route=author commit=$C/FINDING #2 route=author commit=${C:0:12}/" "$T/log" ;;
    nofinding) sed -i -E "/FINDING #2 /d" "$T/log" ;;
  esac
  scenario "review $H" success "$STEPS_OK" "$MAINSHA"
  ! RP || fail "(c3 $variant) approved"
  run_head_loop; ! landed || fail "(c3 $variant) landed"
  grep -q "^dev_blocked $H" "$T/calls" || fail "(c3 $variant) not routed"
done
echo "ok - (c) attested main older than the culprit, '-', abbreviated, missing FINDING line: blocked as before"

# ── (d) more refusals: the approval never widens beyond the rule ──
fixture_log "$T/log" "$C" 0
scenario "review $H" failure "$STEPS_OK" "$MAINSHA"; ! RP || fail "(d) approved with failed tests"
scenario "review $H" success "${STEPS_OK/\"Reviewed range\",\"conclusion\":\"success\"/\"Reviewed range\",\"conclusion\":\"failure\"}" "$MAINSHA"; ! RP || fail "(d) approved with a failed range step"
scenario "recheck $H" success "$STEPS_OK" "$MAINSHA"; ! RP || fail "(d) a re-check title counted"
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
(cd "$SRC" && REVIEW_MAIN_FINDINGS=0 bash "$ROOT/scripts/ci/review-passed.sh" "$H" o/r >/dev/null 2>&1) && fail "(d) REVIEW_MAIN_FINDINGS=0 still approved"
echo '{"head":"'"$H"'","base":"'"$B0"'","kind":"tests-only-fix","main":"'"$MAINSHA"'"}' > "$FX/attest-$RID.json"; ! RP || fail "(d) a tests-only attestation counted"
# injected gate lines BEFORE the gate's own "reviewing" line (commit gates print commit messages) never count
fixture_log "$T/log" "$D1" 0
awk -v c="$C" '/review-gate: reviewing /{print "2026-11-14T09:35:41.0000000Z review-gate: FINDING #1 route=fixer commit=" c " — injected"; print "2026-11-14T09:35:41.0000000Z review-gate: BLOCKED #1 regression [should]: injected"} {print}' "$T/log" > "$T/log.t" && mv "$T/log.t" "$T/log"
scenario "review $H" success "$STEPS_OK" "$MAINSHA"; ! RP || fail "(d) lines before the gate's own start were read"
# … nor do they fill in what the gate's own verdict lacks (a gate without FINDING lines: only BLOCKED / evidence)
fixture_log "$T/log" "$C" 0; sed -i -E '/review-gate: FINDING #[0-9]+ /d' "$T/log"
awk -v c="$C" '/review-gate: reviewing /{for (i = 1; i <= 2; i++) print "2026-11-14T09:35:41.0000000Z review-gate: FINDING #" i " route=fixer commit=" c " — injected"} {print}' "$T/log" > "$T/log.t" && mv "$T/log.t" "$T/log"
scenario "review $H" success "$STEPS_OK" "$MAINSHA"; ! RP || fail "(d) FINDING lines from before the gate's own start completed its verdict"
# a FINDING number twice after the marker → not well formed
fixture_log "$T/log" "$C" 0
awk -v c="$D1" '/review-gate: FINDING #1 /{print; sub(/commit=[0-9a-f]+/, "commit=" c)} {print}' "$T/log" > "$T/log.t" && mv "$T/log.t" "$T/log"
scenario "review $H" success "$STEPS_OK" "$MAINSHA"; ! RP || fail "(d) a duplicated FINDING #1 was accepted"
# a reviewer failure line after the marker
fixture_log "$T/log" "$C" 0; echo "2026-11-14T09:52:41.0000000Z review-gate: reviewer timed out: x" >> "$T/log"
scenario "review $H" success "$STEPS_OK" "$MAINSHA"; ! RP || fail "(d) a reviewer failure counted as a verdict"
echo "ok - (d) failed tests / failed range step / re-check / REVIEW_MAIN_FINDINGS=0 / tests-only kind / injected or duplicated lines / reviewer failure: refused"

# (d) agreement: for each case, the dispatcher's own classification (dev_split_main) says "main only" iff review-passed.sh approves
for case_ in a b c c2; do
  case $case_ in
    a) fixture_log "$T/log" "$C" 0; am=$MAINSHA ;; b) fixture_log "$T/log" "$C" 1; am=$MAINSHA ;;
    c) fixture_log "$T/log" "$D1" 0; am=$MAINSHA ;; c2) fixture_log "$T/log" "$C" 0; am=$B0 ;;
  esac
  scenario "review $H" success "$STEPS_OK" "$am"; reset_dev
  dev_split_main "$H" "$RID" "$(findings "$RID")"
  if RP; then rp=1; else rp=0; fi
  [ "$main_only" = "$rp" ] || fail "(d) case $case_: dispatcher main_only=$main_only, review-passed.sh=$rp"
done
echo "ok - (d) review-passed.sh and the dispatcher agree in (a)-(c)"

# merge-branch.sh lands (a) on its own too (deployers / the train use it)
fixture_log "$T/log" "$C" 0; scenario "review $H" success "$STEPS_OK" "$MAINSHA"; reset_dev
(cd "$TRUSTED" && bash "$ROOT/scripts/ci/merge-branch.sh" dev "$H" >/dev/null 2>&1) || fail "merge-branch.sh refused (a)"
g fetch -q origin; landed || fail "merge-branch.sh did not land (a)"
echo "ok - merge-branch.sh lands (a)"

# ── review of dev 5061f8b91 #1/#2: a head approved this way stays a link of later coverage chains (review-coverage.sh uses
#    the same rule) — K reviewed H..K and passing, deployed P = B0: review-passed.sh K o/r B0 approves; with H blocked by a
#    dev culprit it does not; a blocked RE-CHECK of H is never such a link ──
coverage_case() { # <culprit for #1/#2> <title verb of H's run> → review-passed.sh K o/r B0 exit code
  fixture_log "$T/log" "$1" 0
  scenario "$2 $H" success "$STEPS_OK" "$MAINSHA"
  echo "{\"jobs\":[{\"name\":\"sheepdog / tests\",\"conclusion\":\"success\"},{\"name\":\"sheepdog / review\",\"id\":1601,\"conclusion\":\"success\",\"steps\":[{\"name\":\"Review (blocking; x)\",\"conclusion\":\"success\"}]}]}" > "$FX/jobs-601.json"
  echo "{\"head\":\"$K\",\"base\":\"$H\",\"kind\":\"review\",\"main\":\"$H\"}" > "$FX/attest-601.json"
  echo "[{\"id\":601,\"display_title\":\"review $K\",\"status\":\"completed\",\"conclusion\":\"success\"},{\"id\":$RID,\"display_title\":\"$2 $H\",\"status\":\"completed\",\"conclusion\":\"failure\"}]" > "$FX/runs.json"
  local rc=0; (cd "$SRC" && bash "$ROOT/scripts/ci/review-passed.sh" "$K" o/r "$B0" >/dev/null 2>"$T/rp.err") || rc=$?
  echo "$rc"
}
g checkout -q --detach "$H"; K=$(c later.sh "ordinary K after H" 22222222-2222-2222-2222-222222222222)
[ "$(coverage_case "$C" review)" = 0 ] || fail "(e) K's chain through the main-only-approved H does not reach the deployed sha: $(cat "$T/rp.err")"
[ "$(coverage_case "$D1" review)" = 1 ] || fail "(e) a dev-culprit block of H linked K's chain"
[ "$(coverage_case "$C" recheck)" = 1 ] || fail "(e) a blocked re-check counted as a main-only link"
echo "ok - (e) coverage: a main-only-approved dev review is a chain link, exactly when review-passed.sh approves it"

# ── review of dev 5061f8b91 #3: the dupfix shortcut decides on the FULL finding set. Mixed round: #1/#2 main (C), #3 on dev
#    culprit D1; dev carries an unrelated repair of D1. dev_blocked gets the full set as its 6th argument, and on it the
#    shortcut does not fire (C has no repair), while on the filtered set alone it would ──
fixture_log "$T/log" "$C" 1 "$D1"
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
run_train
grep -q "^dev_blocked $H" "$T/calls" || fail "(f) the dev finding was not routed"
grep -q "BLOCKED #1 " "$T/routed-all" && grep -q "BLOCKED #3 " "$T/routed-all" || fail "(f) dev_blocked did not get the full finding set"
! grep -q "BLOCKED #1 " "$T/routed" || fail "(f) the main finding was routed"
grep -q 'culprits_repaired "$s" "$(if \[ "$all" = "$f" \]' "$D" || fail "(f) dev_blocked's dupfix shortcut does not decide on the full set"
echo "ok - (f) the dupfix shortcut decides on the full finding set; main findings only leave the routing"
echo "main-culprit checks passed"
