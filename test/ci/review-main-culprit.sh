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
#   (g) the train asks review-passed.sh over EVERY blocked review of a sha: a newer reviewer failure never hides an older
#       qualifying run (review of vpn-sub c2cb135f0 #1); the approving run's main findings are recorded before it lands
#       (review of sheepdog dev d9228afe7 #1)
#   (h) … and only once that record is confirmed written: an unavailable routing read → not landed, retried next run
#       (review of sheepdog main 625246776 #1); (i) an unwritable record never yields a main-only approval (train or head
#       loop; review of main 725a2adc1 #1); (j) receipts are per run (review of dev 8ba5aaa38 #1/#2); (k) the head loop
#       is bound to the approving review, (k2) also when its log cannot be read (review of dev 8a8373271 #1); (l) receipts
#       name the review attempt (review of pawx 7f0dbbc8f #1/#2); (m) a repository-local review-passed.sh's pass is a plain
#       pass only after a full-review check; (n) DRY previews without a receipt (review of main 9b7ece173 #1-#3); (l2) one jobs answer
#       binds classification, text and receipt (review of dev 84ada34cc #3)
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
ghm() { # the routing memo: the real (fake) gh; with $T/ghm-logs-fail present, job-log reads fail (an unavailable read)
  # (its content, if any: only that job's log fails)
  if [ -e "$T/ghm-logs-fail" ] && [[ "$*" == *"/jobs/$(cat "$T/ghm-logs-fail")"*"/logs"* ]]; then return 1; fi
  # A recent/uncached log can fail once between a successful initial read and a successful retry.
  if [ -e "$T/fail-log-read-at" ] && [[ "$*" == *"/jobs/$JID/logs"* ]]; then
    local reads=0; [ ! -f "$T/log-reads" ] || reads=$(cat "$T/log-reads")
    reads=$((reads + 1)); echo "$reads" > "$T/log-reads"
    if [ "$reads" = "$(cat "$T/fail-log-read-at")" ]; then return 1; fi
  fi
  # $T/swap-jobs = "<run id> <file>": right after the first read of that run's jobs, the run is rerun (jobs replaced)
  if [ -e "$T/swap-jobs" ] && [[ "$*" == *"/runs/$(cut -d' ' -f1 "$T/swap-jobs")/jobs"* ]]; then
    gh "$@"; local rc=$?; cp "$(cut -d' ' -f2 "$T/swap-jobs")" "$FX/jobs-$(cut -d' ' -f1 "$T/swap-jobs").json"; rm -f "$T/swap-jobs"; return $rc
  fi
  # Rerun immediately after the head loop's initial log read: its caller still has attempt 1's main findings, while
  # dev_split_main will read attempt 2's jobs and dev-only log.
  if [ -e "$T/swap-after-log" ] && [[ "$*" == *"/jobs/$JID/logs"* ]]; then
    gh "$@"; local rc=$?; cp "$T/rerun-jobs.json" "$FX/jobs-$RID.json"; rm -f "$T/swap-after-log"; return $rc
  fi
  gh "$@"; }
ghc_note_jobs() { cat > /dev/null; }
STATE=$T/state MAIN=main DEV=dev TRUSTED=$T/trusted WORK=$T/work OUTBOX=$T/state/outbox CI_SCRIPTS=$ROOT/scripts/ci
DEV_REVERT_AFTER_SEC=3600 DEV_REVERT_WARN_SEC=900 key_prefix="" SUPERVISOR_THREAD=sup DISPATCH_THREAD=disp
mkdir -p "$STATE/sent" "$OUTBOX"; LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
git -C "$SRC" worktree add -q --detach "$TRUSTED" origin/main
eval "$(sed -n '/^review_jobs() {/p; /^review_list() {/,/^}/p; /^dev_round_noop() {/,/^}/p; /^dev_merge_only() {/,/^}/p; /^review_infra_reason() {/,/^}/p; /^run_verdict() {/,/^}/p; /^dev_verdict_run() {/,/^}/p; /^named_files() {/p; /^findings_cap() {/,/^}/p; /^findings() {/,/^}/p; /^notes_of() {/,/^}/p; /^findings_subset() {/,/^}/p; /^main_culprits_api() /p; /^main_culprit_hint() {/,/^}/p; /^dsm_api() {/,/^}/p; /^dev_split_main() {/,/^}/p; /^review_approve() {/,/^}/p; /^record_approving_main() {/,/^}/p; /^thread_of() /p; /^range_threads() {/,/^}/p' "$D")"
source "$ROOT/scripts/ci/review-main-culprits.sh"
source "$ROOT/scripts/ci/review-machinery.sh"
eval "$(sed -n '/^dispatch_msg() {/,/^}/p' "$D")"   # the real revert path's commit message
for f in review_list findings findings_subset main_culprit_hint dev_split_main record_approving_main main_culprits_api review_main_culprits dev_verdict_run; do
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

if [ -z "${REVIEW_MAIN_REGRESSION:-}" ]; then
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
grep -q "finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" 2>/dev/null || fail "(a) the train landed without recording main's findings"
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
# ── review of vpn-sub c2cb135f0 #1: the train weighs EVERY blocked review of a sha, not only the newest. H has an older run
#    blocked only by main findings (qualifies) and a newer run whose reviewer failed (infrastructure, no verdict); the
#    newest one alone would hide the older approval and strand H ──
fixture_log "$T/log" "$C" 0
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
NRID=$((RID + 1)); NJID=$((JID + 1))
echo "{\"jobs\":[{\"name\":\"sheepdog / tests\",\"conclusion\":\"success\"},{\"name\":\"sheepdog / review\",\"id\":$NJID,\"conclusion\":\"failure\",\"steps\":[$STEPS_OK]}]}" > "$FX/jobs-$NRID.json"
grep -m1 'review-gate: reviewing ' "$T/log" > "$FX/log-$NJID.txt"
echo "2026-11-15T05:00:00.0000000Z review-gate: reviewer failed: spawn E2BIG" >> "$FX/log-$NJID.txt"
echo "{\"head\":\"$H\",\"base\":\"$B0\",\"kind\":\"review\",\"main\":\"$MAINSHA\"}" > "$FX/attest-$NRID.json"
echo "[{\"id\":$NRID,\"display_title\":\"review $H\",\"status\":\"completed\",\"conclusion\":\"failure\"},{\"id\":$RID,\"display_title\":\"review $H\",\"status\":\"completed\",\"conclusion\":\"failure\"}]" > "$FX/runs.json"
RP || fail "(g) review-passed.sh does not approve H from its older main-only run: $(cat "$T/rp.err")"
run_train
grep -q 'BLOCKED #1 ' "$STATE/open-findings.log" 2>/dev/null || fail "(g) qualifying main findings were not recorded"
landed || fail "(g) the train stranded H behind a newer infrastructure-failed review: $(cat "$LOG" 2>/dev/null)"
! grep -qE '^(dev_blocked|wake_fixer|notify)' "$T/calls" 2>/dev/null || fail "(g) the train routed main's findings: $(cat "$T/calls")"
# … and records the approving (older) run's main findings before landing: later reviews see them as known-open
# (review of sheepdog dev d9228afe7 #1)
grep -q "run $RID): finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" 2>/dev/null || fail "(g) the train landed H without recording its main findings: $(cat "$STATE/open-findings.log" 2>/dev/null)"
[ "$(grep -c '^review-gate: BLOCKED #[12] ' "$STATE/open-findings.log")" = 2 ] || fail "(g) the known-open feed lacks the BLOCKED lines"
# … and a sha whose every blocked review has a dev finding still does not land through the train
fixture_log "$T/log" "$C" 1; cp "$T/log" "$FX/log-$JID.txt"
run_train
! landed || fail "(g) the train landed a sha whose only verdict has a dev finding"
echo "ok - (g) the train lands a sha whose older review blocked only on main findings behind a newer reviewer failure"
# ── review of sheepdog main 625246776 #1: the train lands a main-only approval only once its findings are RECORDED. The
#    routing read of the approving job's log fails (ghm; review-passed.sh's own reads succeed) → approved but not landed,
#    nothing recorded, logged; the next run with a good read records, then lands ──
fixture_log "$T/log" "$C" 0
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
RP || fail "(h) review-passed.sh does not approve (a)"
reset_dev; touch "$T/ghm-logs-fail"
( cd "$ROOT" && DRY="" && eval "$train" ) || fail "(h) train failed"; g fetch -q origin
! landed || fail "(h) the train landed H although its main findings could not be recorded"
test ! -s "$STATE/open-findings.log" || fail "(h) recorded something from an unavailable read"
grep -q "could not be recorded in open-findings.log — not landed this run" "$LOG" || fail "(h) no log line for the unrecorded approval: $(cat "$LOG" 2>/dev/null)"
rm -f "$T/ghm-logs-fail"
( cd "$ROOT" && DRY="" && eval "$train" ) || fail "(h) train failed"; g fetch -q origin   # next run, state kept
grep -q "run $RID): finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" 2>/dev/null || fail "(h) the retry did not record the findings"
landed || fail "(h) the retry did not land H: $(cat "$LOG" 2>/dev/null)"
echo "ok - (h) a main-only approval lands only after its findings are recorded; an unavailable read retries next run"
# ── review of sheepdog main 725a2adc1 #1: open-findings.log cannot be written (here: a directory) → no caller treats the
#    run as main-only; neither the train nor the head loop that follows it lands H; nothing routed as main's ──
fixture_log "$T/log" "$C" 0
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
reset_dev; mkdir "$STATE/open-findings.log"
( cd "$ROOT" && DRY="" && eval "$train" ) || fail "(i) train failed"; g fetch -q origin
! landed || fail "(i) the train landed H with an unwritable open-findings.log"
( cd "$ROOT" && merged_one=0 && DRY="" && eval "$loop" ) || fail "(i) head loop failed"; g fetch -q origin
! landed || fail "(i) the head loop merged H with an unwritable open-findings.log: $(cat "$LOG")"
grep -q "open-findings.log could not be written" "$LOG" || fail "(i) no log line for the failed record"
! grep -qE '^(dev_blocked|wake_fixer|notify)' "$T/calls" 2>/dev/null || fail "(i) main findings were routed on dev after a failed record: $(cat "$T/calls")"
test ! -e "$STATE/dev.blocked_since" || fail "(i) a dev block clock started for main's findings"
# … also with an aged block clock (review of main 6b9031dfb #1): main's findings never reach dev's revert path
dev_before=$(g rev-parse origin/dev); echo $(( $(date +%s) - 4000 )) > "$STATE/dev.blocked_since"; echo "$H" > "$STATE/dev.blocked_since.sha"
( cd "$ROOT" && merged_one=0 && DRY="" && eval "$loop" ) >/dev/null 2>&1; g fetch -q origin
[ "$(g rev-parse origin/dev)" = "$dev_before" ] || fail "(i) dev was rewritten (revert) for main's findings after a failed record"
! landed || fail "(i) landed with an aged clock"
! grep -qE '^(dev_blocked|wake_fixer)' "$T/calls" 2>/dev/null || fail "(i) routed with an aged clock: $(cat "$T/calls")"
rm -f "$STATE/dev.blocked_since" "$STATE/dev.blocked_since.sha"
ls "$STATE/sent/" | grep -q mainfindings && fail "(i) a receipt without a record"
rmdir "$STATE/open-findings.log"
echo "ok - (i) a record that cannot be written: no main-only approval, H not landed by the train or the head loop"

# ── review of sheepdog dev 8ba5aaa38 #1/#2: receipts are per run. H's newer run 501 (failed tests, main finding #1 only) is
#    recorded first; the train's approving run is the older 500 (#1 and #2): its own findings are recorded before landing ──
fixture_log "$T/log" "$C" 0
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
NRID=$((RID + 1)); NJID=$((JID + 1))
echo "{\"jobs\":[{\"name\":\"sheepdog / tests\",\"conclusion\":\"failure\"},{\"name\":\"sheepdog / review\",\"id\":$NJID,\"conclusion\":\"failure\",\"steps\":[$STEPS_OK]}]}" > "$FX/jobs-$NRID.json"
awk '/review-gate: (FINDING|BLOCKED) #2 /{skip = 1; next} skip && /^[^ ]+ evidence:/{skip = 0; next} {skip = 0; print}' "$T/log" > "$FX/log-$NJID.txt"
echo "{\"head\":\"$H\",\"base\":\"$B0\",\"kind\":\"review\",\"main\":\"$MAINSHA\"}" > "$FX/attest-$NRID.json"
echo "[{\"id\":$NRID,\"display_title\":\"review $H\",\"status\":\"completed\",\"conclusion\":\"failure\"},{\"id\":$RID,\"display_title\":\"review $H\",\"status\":\"completed\",\"conclusion\":\"failure\"}]" > "$FX/runs.json"
reset_dev
( DRY=""; dev_split_main "$H" "$NRID" "$(findings "$NRID")"; [ "$main_only" = 1 ] ) || fail "(j) fixture: run $NRID is not main-only"
grep -q "run $NRID): finding(s) 1 — culprit on main" "$STATE/open-findings.log" || fail "(j) fixture: run $NRID not recorded"
( cd "$ROOT" && DRY="" && eval "$train" ) || fail "(j) train failed"; g fetch -q origin
landed || fail "(j) the train did not land H: $(cat "$LOG")"
grep -q "run $RID): finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" || fail "(j) the approving run $RID's findings were not recorded (another run's receipt counted)"
echo "ok - (j) receipts are per run: the approving run's own findings are recorded before landing"
# ── review of pawx-twitter-poller 7f0dbbc8f #1: the BRANCH-HEAD loop is bound to the approving review too. The head loop
#    selects H's newest run 501 (main finding #1 only, failed tests, already recorded); review-passed.sh approves through
#    the older run 500 (#1/#2) — its findings are recorded before the head loop lands H ──
fixture_log "$T/log" "$C" 0
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
NRID=$((RID + 1)); NJID=$((JID + 1))
echo "{\"jobs\":[{\"name\":\"sheepdog / tests\",\"conclusion\":\"failure\"},{\"name\":\"sheepdog / review\",\"id\":$NJID,\"conclusion\":\"failure\",\"steps\":[$STEPS_OK]}]}" > "$FX/jobs-$NRID.json"
awk '/review-gate: (FINDING|BLOCKED) #2 /{skip = 1; next} skip && /^[^ ]+ evidence:/{skip = 0; next} {skip = 0; print}' "$T/log" > "$FX/log-$NJID.txt"
echo "{\"head\":\"$H\",\"base\":\"$B0\",\"kind\":\"review\",\"main\":\"$MAINSHA\"}" > "$FX/attest-$NRID.json"
echo "[{\"id\":$NRID,\"display_title\":\"review $H\",\"status\":\"completed\",\"conclusion\":\"failure\"},{\"id\":$RID,\"display_title\":\"review $H\",\"status\":\"completed\",\"conclusion\":\"failure\"}]" > "$FX/runs.json"
reset_dev
( DRY=""; dev_split_main "$H" "$NRID" "$(findings "$NRID")" ) >/dev/null
( cd "$ROOT" && merged_one=0 && DRY="" && eval "$loop" ) || fail "(k) head loop failed"; g fetch -q origin
if landed; then
  grep -q "run $RID): finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" || fail "(k) the head loop landed H without the approving run $RID's findings: $(cat "$STATE/open-findings.log")"
fi
( cd "$ROOT" && merged_one=0 && DRY="" && eval "$loop" ) >/dev/null 2>&1; g fetch -q origin
landed || fail "(k) the head loop never landed H: $(cat "$LOG")"
grep -q "run $RID): finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" || fail "(k) run $RID's findings missing after landing"
echo "ok - (k) the branch-head loop lands a main-only approval only with the APPROVING run's findings recorded"
# (k2) review of sheepdog dev 8a8373271 #1: the same, with the routing read of run 500's review log failing — the head loop
#     must not land H on run 501's record; once the read works, run 500's findings are recorded, then H lands
reset_dev
( DRY=""; dev_split_main "$H" "$NRID" "$(findings "$NRID")" ) >/dev/null
echo "$JID" > "$T/ghm-logs-fail"
( cd "$ROOT" && merged_one=0 && DRY="" && eval "$loop" ) >/dev/null 2>&1; g fetch -q origin
! landed || fail "(k2) the head loop landed H via run $RID with only run $NRID's findings recorded"
( cd "$ROOT" && DRY="" && eval "$train" ) >/dev/null 2>&1; g fetch -q origin
! landed || fail "(k2) the train landed H via run $RID with only run $NRID's findings recorded"
rm -f "$T/ghm-logs-fail"
( cd "$ROOT" && merged_one=0 && DRY="" && eval "$loop" ) >/dev/null 2>&1; g fetch -q origin
landed && grep -q "run $RID): finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" || fail "(k2) after the read recovered: landed=$(landed && echo 1 || echo 0), log: $(cat "$STATE/open-findings.log")"
echo "ok - (k2) an unreadable approving-run log keeps H unlanded (head loop and train); recorded and landed once readable"

# ── review of pawx-twitter-poller 7f0dbbc8f #2: receipts name the review attempt. Run 500's first attempt (job $JID)
#    reported only #1 and was recorded; its rerun (attempt 2, a new review job) reports #1/#2 → recorded again before H lands ──
fixture_log "$T/log" "$C" 0
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
awk '/review-gate: (FINDING|BLOCKED) #2 /{skip = 1; next} skip && /^[^ ]+ evidence:/{skip = 0; next} {skip = 0; print}' "$T/log" > "$FX/log-$JID.txt"
reset_dev
( DRY=""; dev_split_main "$H" "$RID" "$(findings "$RID")"; [ "$main_only" = 1 ] ) || fail "(l) fixture: attempt 1 not main-only"
grep -q "run $RID): finding(s) 1 — culprit on main" "$STATE/open-findings.log" || fail "(l) fixture: attempt 1 not recorded"
RJID=$((JID + 7))
echo "{\"jobs\":[{\"name\":\"sheepdog / tests\",\"conclusion\":\"success\",\"run_attempt\":2},{\"name\":\"sheepdog / review\",\"id\":$RJID,\"run_attempt\":2,\"conclusion\":\"failure\",\"steps\":[$STEPS_OK]}]}" > "$FX/jobs-$RID.json"
cp "$T/log" "$FX/log-$RJID.txt"
( cd "$ROOT" && DRY="" && eval "$train" ) || fail "(l) train failed"; g fetch -q origin
landed || fail "(l) the train did not land H: $(cat "$LOG")"
grep -q "run $RID): finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" || fail "(l) the rerun's findings #1/#2 were not recorded (the first attempt's receipt counted)"
test -e "$STATE/sent/$H.$RID.2.$RJID.mainfindings" || fail "(l) no receipt for attempt 2 / job $RJID"
echo "ok - (l) receipts name the review attempt: a rerun's findings are recorded before landing"
# (l2) review of dev 84ada34cc #3: a rerun right after the first jobs read. The classification, the recorded text and the
#     receipt all come from that one answer (attempt 1, job $JID, #1 only); the rerun's attempt 2 / job $RJID (#1/#2) is
#     never marked recorded by it, and recording that attempt later writes #1/#2
fixture_log "$T/log" "$C" 0
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
awk '/review-gate: (FINDING|BLOCKED) #2 /{skip = 1; next} skip && /^[^ ]+ evidence:/{skip = 0; next} {skip = 0; print}' "$T/log" > "$FX/log-$JID.txt"
cp "$T/log" "$FX/log-$RJID.txt"
echo "{\"jobs\":[{\"name\":\"sheepdog / tests\",\"conclusion\":\"success\",\"run_attempt\":2},{\"name\":\"sheepdog / review\",\"id\":$RJID,\"run_attempt\":2,\"conclusion\":\"failure\",\"steps\":[$STEPS_OK]}]}" > "$T/rerun-jobs.json"
reset_dev; echo "$RID $T/rerun-jobs.json" > "$T/swap-jobs"
( DRY=""; dev_split_main "$H" "$RID" "$(cat "$FX/log-$JID.txt" | sed -E 's/^[^ ]+ //' | grep -E '^(review-gate: (BLOCKED|FINDING)|evidence:)')" ) >/dev/null
rm -f "$T/swap-jobs"
test -e "$STATE/sent/$H.$RID.1.$JID.mainfindings" || fail "(l2) the first attempt's receipt is not named by its own job: $(ls "$STATE/sent")"
test ! -e "$STATE/sent/$H.$RID.2.$RJID.mainfindings" || fail "(l2) the rerun attempt was marked recorded with the first attempt's findings"
echo "$RID 2 $RJID main" > "$T/l2.approval"
( DRY=""; record_approving_main "$H" "$T/l2.approval" ) || fail "(l2) recording the rerun attempt failed"
grep -q "run $RID): finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" || fail "(l2) the rerun's #1/#2 were not recorded"
echo "ok - (l2) one jobs answer binds classification, text and receipt: a rerun between reads is recorded on its own"
# ── review of sheepdog main 9b7ece173 #1/#2: a repository-local (older) review-passed.sh writes no approval file. Its
#    approval is a plain full-review pass: the train and the head loop land on it, and it is asked with
#    REVIEW_MAIN_FINDINGS=0 before accepting its receiptless pass ──
LEG=$T/legacy-ci; rm -rf "$LEG"; cp -r "$ROOT/scripts/ci" "$LEG"
cat > "$LEG/review-passed.sh" <<'RP'
#!/usr/bin/env bash
# a repository-local contract script from before REVIEW_APPROVAL_OUT: approves, writes no approval file
echo "${REVIEW_MAIN_FINDINGS:-unset}" >> "$FX/legacy-rp-main"
[ -z "${REVIEW_KIND_OUT:-}" ] || echo review > "$REVIEW_KIND_OUT"
echo "trusted tests + review passed for ${1:0:12} (run 1)"
RP
fixture_log "$T/log" "$C" 0
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
rm -f "$FX/legacy-rp-main"; reset_dev
( cd "$ROOT" && DRY="" && CI_SCRIPTS=$LEG && eval "$train" ) || fail "(m) train failed"; g fetch -q origin
landed || fail "(m) the train refused a legacy script's plain pass: $(cat "$LOG")"
[ "$(tail -1 "$FX/legacy-rp-main")" = 0 ] || fail "(m) the legacy script was not checked with main findings disabled"
rm -f "$FX/legacy-rp-main"; reset_dev
( cd "$ROOT" && merged_one=0 && DRY="" && CI_SCRIPTS=$LEG && eval "$loop" ) || fail "(m) head loop failed"; g fetch -q origin
landed || fail "(m) the head loop refused a legacy script's plain pass: $(cat "$LOG")"
[ "$(tail -1 "$FX/legacy-rp-main")" = 0 ] || fail "(m) head loop: the legacy script was not checked with main findings disabled"
# … while sheepdog's own checker with an empty approval file is still refused (unreadable evidence)
printf '' > "$T/empty.approval"; ( approval_named=1; ! record_approving_main "$H" "$T/empty.approval" ) || fail "(m) an empty approval file of sheepdog's checker was accepted"
echo "ok - (m) a repository-local review-passed.sh: receiptless pass requires a check with main findings disabled"

# ── review of sheepdog main 9b7ece173 #3: DRY previews a main-only merge from the classification alone (no receipt) ──
fixture_log "$T/log" "$C" 0
scenario "review $H" success "$STEPS_OK" "$MAINSHA"
reset_dev
out=$( cd "$ROOT" && merged_one=0 && DRY=1 && eval "$loop" 2>&1 ) || fail "(n) DRY head loop failed"
grep -q "DRY merge dev ${H:0:9}" <<<"$out" || fail "(n) DRY did not preview the main-only merge: $out"
! landed || fail "(n) DRY landed"
test ! -s "$STATE/open-findings.log" || fail "(n) DRY wrote a record"
echo "ok - (n) DRY previews a main-only merge without a receipt and writes nothing"
fi

# Focused regressions for the main review of 76fdca743. Select with REVIEW_MAIN_REGRESSION=refresh|local-contract.
if [ -z "${REVIEW_MAIN_REGRESSION:-}" ] || [ "$REVIEW_MAIN_REGRESSION" = refresh ]; then
  fixture_log "$T/log" "$C" 0
  scenario "review $H" success "$STEPS_OK" "$MAINSHA"
  reset_dev; echo 2 > "$T/fail-log-read-at"; rm -f "$T/log-reads"
  ( cd "$ROOT" && merged_one=0 && DRY="" && eval "$loop" ) || fail "(o) head loop failed"
  g fetch -q origin
  if landed; then
    [ "$(grep -c '^review-gate: BLOCKED #[12] ' "$STATE/open-findings.log")" = 2 ] || fail "(o) landed with a receipt but missing findings after the failed refresh"
  fi
  for receipt in "$STATE/sent/"*.mainfindings; do
    [ ! -e "$receipt" ] || [ "$(grep -c '^review-gate: BLOCKED #[12] ' "$STATE/open-findings.log")" = 2 ] || fail "(o) certified an empty record"
  done
  rm -f "$T/fail-log-read-at" "$T/log-reads"
  ( cd "$ROOT" && merged_one=0 && DRY="" && eval "$loop" ) || fail "(o) head retry failed"
  g fetch -q origin
  landed || fail "(o) head did not land after reads recovered"
  [ "$(grep -c '^review-gate: BLOCKED #[12] ' "$STATE/open-findings.log")" = 2 ] || fail "(o) retry omitted findings"

  # The post-approval guard must also reject this sequence, even with a valid caller-supplied initial read.
  reset_dev; echo 2 > "$T/fail-log-read-at"; rm -f "$T/log-reads"
  echo "$RID 1 $JID main" > "$T/o.approval"
  if ( DRY=""; record_approving_main "$H" "$T/o.approval" ); then
    [ "$(grep -c '^review-gate: BLOCKED #[12] ' "$STATE/open-findings.log")" = 2 ] || fail "(o) record_approving_main accepted an empty record"
  fi
  test ! -e "$STATE/sent/$H.$RID.1.$JID.mainfindings" || fail "(o) failed log read created a receipt"
  rm -f "$T/fail-log-read-at" "$T/log-reads"
  ( DRY=""; record_approving_main "$H" "$T/o.approval" ) || fail "(o) guard retry did not record"
  echo "ok - (o) a failed refresh cannot certify an empty record; head and guard recover on retry"
fi

if [ -z "${REVIEW_MAIN_REGRESSION:-}" ] || [ "$REVIEW_MAIN_REGRESSION" = local-contract ]; then
  fixture_log "$T/log" "$C" 0
  scenario "review $H" success "$STEPS_OK" "$MAINSHA"
  # Use the production initialization, including CI_SCRIPTS selection, for a repository-local capable checker.
  init=$(python3 - "$D" <<'PYINIT'
import sys
s = open(sys.argv[1]).read()
a = s.index('if [ -f "$TRUSTED/.github/sheepdog.yml" ]')
print(s[a:s.index('\nsource ', a)])
PYINIT
)
  mkdir -p "$TRUSTED/scripts/ci"; cp "$ROOT/scripts/ci/"*.sh "$TRUSTED/scripts/ci/"
  for path in head train; do
    reset_dev
    ( SHEEPDOG_CI=$ROOT/scripts/ci; unset approval_named; eval "$init"; DRY=""; merged_one=0
      if [ "$path" = head ]; then eval "$loop"; else eval "$train"; fi
    ) || fail "(p) local capable $path failed"
    g fetch -q origin
    landed || fail "(p) $path stranded a receipt-capable repository-local checker: $(cat "$LOG")"
    test -e "$STATE/sent/$H.$RID.1.$JID.mainfindings" || fail "(p) local capable $path bypassed the receipt guard"
    [ "$(grep -c '^review-gate: BLOCKED #[12] ' "$STATE/open-findings.log")" = 2 ] || fail "(p) local capable $path omitted findings"
  done
  # A historical receipt-capable local checker has no capability declaration, but its approval sidecar still works.
  git -C "$ROOT" show 76fdca743b72d1a0e481d5ca1a2cef1d47a176b7:scripts/ci/review-passed.sh > "$TRUSTED/scripts/ci/review-passed.sh"
  for path in head train; do
    reset_dev
    ( SHEEPDOG_CI=$ROOT/scripts/ci; unset approval_named; eval "$init"; DRY=""; merged_one=0
      if [ "$path" = head ]; then eval "$loop"; else eval "$train"; fi
    ) || fail "(p) historical capable $path failed"
    g fetch -q origin
    landed || fail "(p) $path stranded a historical receipt-capable local checker"
    test -e "$STATE/sent/$H.$RID.1.$JID.mainfindings" || fail "(p) historical capable $path bypassed recording"
  done
  # Legacy main-only approvals without a sidecar are refused when the full-review fallback refuses.
  LEG=$T/legacy-ci; mkdir -p "$LEG"; cp "$ROOT/scripts/ci/"*.sh "$LEG/"
  cat > "$LEG/review-passed.sh" <<'RP'
#!/usr/bin/env bash
echo "${REVIEW_MAIN_FINDINGS:-unset}" >> "$FX/legacy-rp-main"
[ -z "${REVIEW_KIND_OUT:-}" ] || echo review > "$REVIEW_KIND_OUT"
[ "${REVIEW_MAIN_FINDINGS:-1}" != 0 ] || [ -e "$FX/legacy-allow-pass" ]
RP
  for path in head train; do
    reset_dev; rm -f "$FX/legacy-rp-main"
    ( CI_SCRIPTS=$LEG; DRY=""; merged_one=0
      if [ "$path" = head ]; then eval "$loop"; else eval "$train"; fi
    ) || fail "(p) legacy $path failed"
    g fetch -q origin
    ! landed || fail "(p) $path accepted a receiptless main-only approval"
    [ "$(tail -1 "$FX/legacy-rp-main")" = 0 ] || fail "(p) $path did not require a full-review check from the legacy checker"
    if [ "$path" = head ]; then
      ! grep -qE '^(dev_blocked|wake_fixer)' "$T/calls" 2>/dev/null || fail "(p) legacy checker routed main findings on dev"
      test ! -e "$STATE/dev.blocked_since" || fail "(p) legacy checker started a dev revert clock for main findings"
    fi
    [ "$(grep -c '^review-gate: BLOCKED #[12] ' "$STATE/open-findings.log")" = 2 ] || fail "(p) legacy checker lost main findings"
  done
  touch "$FX/legacy-allow-pass"
  for path in head train; do
    reset_dev; rm -f "$FX/legacy-rp-main"
    ( CI_SCRIPTS=$LEG; DRY=""; merged_one=0
      if [ "$path" = head ]; then eval "$loop"; else eval "$train"; fi
    ) || fail "(p) legacy plain pass $path failed"
    g fetch -q origin
    landed || fail "(p) $path refused a legacy full-review pass"
    [ "$(tail -1 "$FX/legacy-rp-main")" = 0 ] || fail "(p) legacy merge did not keep main findings disabled"
  done
  cat > "$LEG/review-passed.sh" <<'RP'
#!/usr/bin/env bash
[ -z "${REVIEW_APPROVAL_OUT:-}" ] || echo 'bad receipt' > "$REVIEW_APPROVAL_OUT"
RP
  for path in head train; do
    reset_dev
    ( CI_SCRIPTS=$LEG; DRY=""; merged_one=0
      if [ "$path" = head ]; then eval "$loop"; else eval "$train"; fi
    ) || fail "(p) malformed receipt $path failed"
    g fetch -q origin
    ! landed || fail "(p) $path waived a malformed receipt"
  done
  # Explicit capability survives an unsuccessful check. Missing receipts and temporary approval failures cannot turn
  # a capable checker into a legacy checker and route already-classified main findings into a dev fixer/revert.
  cat > "$LEG/review-passed.sh" <<'RP'
#!/usr/bin/env bash
printf '%s\n' receipt-v1 > "$REVIEW_APPROVAL_PROTOCOL_OUT"
[ -z "${REVIEW_KIND_OUT:-}" ] || echo review > "$REVIEW_KIND_OUT"
exit "${CAP_CHECK_RC:-1}"
RP
  for checker_rc in 0 1; do
    for path in head train; do
      reset_dev
      ( export CAP_CHECK_RC=$checker_rc; CI_SCRIPTS=$LEG; DRY=""; merged_one=0
        if [ "$path" = head ]; then eval "$loop"; else eval "$train"; fi
      ) || fail "(p) declared capable $path failed"
      g fetch -q origin
      ! landed || fail "(p) $path accepted a missing receipt from a declared capable checker"
      ! grep -qE '^(dev_blocked|wake_fixer)' "$T/calls" 2>/dev/null || fail "(p) $path routed main findings after a declared capable check failed"
      test ! -e "$STATE/dev.blocked_since" || fail "(p) declared capable checker started a dev revert clock"
    done
  done
  echo "ok - (p) local capable and legacy full-review passes land; receiptless main-only and malformed receipts cannot land"
fi

# Main review of 03f6fcd72 #1: approval capability is separate from ownership. Exercise the actual head loop, including
# its revert path against a fixture remote, with unrelated dev work in the file named by main's findings.
if [ -z "${REVIEW_MAIN_REGRESSION:-}" ] || [ "$REVIEW_MAIN_REGRESSION" = ownership ]; then
  H=$(c scripts/ci/dev-review-base.sh "unrelated dev edit in main finding's file")
  unrelated=$(g show "$H:scripts/ci/dev-review-base.sh")
  LEG=$T/ownership-ci; mkdir -p "$LEG"; cp "$ROOT/scripts/ci/"*.sh "$LEG/"
  for checker in historical legacy; do
    if [ "$checker" = historical ]; then
      # Receipt-capable before protocol declarations; an unavailable approval API writes no sidecar. Only this
      # checker's reads fail: the dispatcher's routing reads still classify the main findings successfully.
      { printf '#!/usr/bin/env bash\ngh() { return 1; }\n'
        git -C "$ROOT" show 76fdca743b72d1a0e481d5ca1a2cef1d47a176b7:scripts/ci/review-passed.sh
      } > "$LEG/review-passed.sh"
    else
      printf '#!/usr/bin/env bash\nexit 1\n' > "$LEG/review-passed.sh"
    fi
    fixture_log "$T/log" "$C" 0
    scenario "review $H" success "$STEPS_OK" "$MAINSHA"
    for episode in overdue fresh; do
      reset_dev
      if [ "$episode" = overdue ]; then
        echo $(( $(date +%s) - 4000 )) > "$STATE/dev.blocked_since"; echo "$H" > "$STATE/dev.blocked_since.sha"
      fi
      ( cd "$ROOT" && CI_SCRIPTS=$LEG && merged_one=0 && DRY="" && eval "$loop" ) || fail "(q) $checker $episode head loop failed"
      g fetch -q origin
      ! landed || fail "(q) $checker $episode landed without approval"
      [ "$(g rev-parse origin/dev)" = "$H" ] || fail "(q) $checker $episode reverted unrelated dev work for main findings"
      [ "$(g show origin/dev:scripts/ci/dev-review-base.sh)" = "$unrelated" ] || fail "(q) $checker $episode lost the unrelated edit"
      ! grep -qE '^(dev_blocked|wake_fixer|notify)' "$T/calls" 2>/dev/null || fail "(q) $checker $episode routed main findings on dev"
      [ "$(grep -c '^review-gate: BLOCKED #[12] ' "$STATE/open-findings.log")" = 2 ] || fail "(q) $checker $episode lost the main findings record"
      if [ "$episode" = fresh ]; then
        test ! -e "$STATE/dev.blocked_since" || fail "(q) $checker started a dev block clock for main findings"
      fi
    done
    # Mixed findings remain blocked and route the dev defect only, even without approval support.
    fixture_log "$T/log" "$C" 1
    scenario "review $H" success "$STEPS_OK" "$MAINSHA"
    reset_dev
    ( cd "$ROOT" && CI_SCRIPTS=$LEG && merged_one=0 && DRY="" && eval "$loop" ) || fail "(q) $checker mixed head loop failed"
    ! landed || fail "(q) $checker landed a mixed review"
    [ "$(routed_nums)" = 3 ] || fail "(q) $checker mixed routed '$(routed_nums)', want only 3"
  done
  echo "ok - (q) approval capability cannot route main findings or revert unrelated dev work; mixed reviews route only dev"
fi

# Main review of 03f6fcd72 #2: the rerun's successful snapshot must replace stale routing even with NO main findings.
if [ -z "${REVIEW_MAIN_REGRESSION:-}" ] || [ "$REVIEW_MAIN_REGRESSION" = rerun-dev ]; then
  fixture_log "$T/log" "$C" 0
  scenario "review $H" success "$STEPS_OK" "$MAINSHA"
  RJID=$((JID + 7))
  fixture_log "$T/rerun-log" "$C" 1
  awk '/review-gate: reviewing / || /review-gate: (FINDING|BLOCKED) #3 / || /evidence: scripts\/ci\/review-dispatch.sh:1114 /' "$T/rerun-log" > "$FX/log-$RJID.txt"
  echo "{\"jobs\":[{\"name\":\"sheepdog / tests\",\"conclusion\":\"success\",\"run_attempt\":2},{\"name\":\"sheepdog / review\",\"id\":$RJID,\"run_attempt\":2,\"conclusion\":\"failure\",\"steps\":[$STEPS_OK]}]}" > "$T/rerun-jobs.json"
  reset_dev; touch "$T/swap-after-log"
  ( cd "$ROOT" && merged_one=0 && DRY="" && eval "$loop" ) || fail "(r) rerun head loop failed"
  g fetch -q origin
  test ! -e "$T/swap-after-log" || fail "(r) fixture did not replace attempt 1 after the initial log read"
  ! landed || fail "(r) landed with the rerun's dev finding"
  [ "$(routed_nums)" = 3 ] || fail "(r) routed '$(routed_nums)', want current dev finding 3"
  grep -q "commit=$H" "$T/routed" && ! grep -q "commit=$C" "$T/routed" || fail "(r) routed text came from the obsolete attempt"
  grep -q 'new rest fixer receipt is missing from lifecycle consumers' "$T/routed" || fail "(r) omitted current dev finding text"
  test ! -s "$STATE/open-findings.log" || fail "(r) recorded obsolete main findings"
  ! ls "$STATE/sent/" | grep -q mainfindings || fail "(r) certified obsolete main findings"
  echo "ok - (r) rerun from main-only to dev-only findings routes the new attempt's dev defect only"
fi
echo "main-culprit checks passed"
