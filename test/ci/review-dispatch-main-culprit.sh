#!/usr/bin/env bash
# Findings of a dev review whose culprit is already on main (docs/contract.md, Findings; docs/dispatcher.md). The reviewer
# reports them as [pre-existing] notes in a dev review (review-gate.ts --dev-main; reviewer/test/review-gate.test.ts); a
# review by an older pinned reviewer can still print them as BLOCKED. The real case: the dev review of 0cd95ca42 (run
# 43577623889, its log in lib/review-0cd95ca42.log with the shas as placeholders) blocked on FINDING #1/#2 whose commit was
# already on main plus #3, the head's own. The dispatcher (dev_main_split, local only) never routes main's findings on
# dev and never lands anything because of them:
#   (a) only main findings → head loop and train: no fixer, no round, no notice, no block clock, nothing landed; the
#       findings are appended ONCE to open-findings.log (the next reviews' known-open list)
#   (b) mixed → only the dev finding (#3) is routed; dev_blocked's dupfix shortcut still sees the full set
#   (c) culprit off main / "-" / abbreviated / no FINDING line → routed as before, nothing recorded
#   (d) the overdue revert names only the dev findings' files: main's findings never reach it (review of sheepdog main
#       03f6fcd72 #1 — whatever contract scripts are in use, migrated or repository-local, there is no other path)
#   (e) a rerun of the same run whose log has other findings is classified from the findings read now (review of main
#       03f6fcd72 #2: no receipt or stale attempt can route the old findings or drop the new dev one)
#   (f) no landing machinery is left: review-passed.sh / merge-branch.sh / review-coverage.sh have no main-findings path
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

# ── history: main B0 → C (main's culprit); dev D0 (touches the file main's findings name) → D1 → merge main → H ──
git init -q --bare "$T/remote.git"; SRC=$T/src; git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
c() { mkdir -p "$SRC/$(dirname "$1")"; echo "$RANDOM$RANDOM" >> "$SRC/$1"; g add "$1"; g commit -q -m "$2" -m "Loop: adhoc/x
Thread: mcp:${3:-11111111-1111-1111-1111-111111111111}"; g rev-parse HEAD; }
B0=$(c base.txt base)
g checkout -q -b dev
D0=$(c scripts/ci/dev-review-base.sh "dev work on the file main's findings name" 33333333-3333-3333-3333-333333333333)
D1=$(c scripts/ci/review-dispatch.sh "dev work" 22222222-2222-2222-2222-222222222222)
g checkout -q main; C=$(c main.txt "fix(review): main's culprit (like 341cca4e9)")
g push -q origin main
g checkout -q dev; g merge -q --no-ff main -m "merge main into dev"
H=$(c scripts/ci/review-dispatch.sh "fix(dispatch): the reviewed dev head (like 0cd95ca42)" 22222222-2222-2222-2222-222222222222)
g push -q origin dev; g fetch -q origin
MAINSHA=$(g rev-parse origin/main)

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
STEPS='{"name":"Reviewed range","conclusion":"success"},{"name":"Review (blocking; sheepdog'"'"'s reviewer, this repository'"'"'s diff)","conclusion":"failure"}'
scenario() { # one completed, failed dev review run of H with the log in $T/log
  rm -f "$FX"/*.json "$FX"/log-* "$FX/calls"
  echo "{\"jobs\":[{\"name\":\"sheepdog / tests\",\"conclusion\":\"success\"},{\"name\":\"sheepdog / review\",\"id\":$JID,\"conclusion\":\"failure\",\"steps\":[$STEPS]}]}" > "$FX/jobs-$RID.json"
  cp "$T/log" "$FX/log-$JID.txt"
  echo "{\"head\":\"$H\",\"base\":\"$B0\",\"kind\":\"review\",\"main\":\"$MAINSHA\"}" > "$FX/attest-$RID.json"
  echo "[{\"id\":$RID,\"display_title\":\"review $H\",\"status\":\"completed\",\"conclusion\":\"failure\"}]" > "$FX/runs.json"
}

# ── the dispatcher's head loop and merge train: the real code, stubbed effects ──
ghm() { gh "$@"; }
ghc_note_jobs() { cat > /dev/null; }
STATE=$T/state MAIN=main DEV=dev TRUSTED=$T/trusted WORK=$T/work OUTBOX=$T/state/outbox CI_SCRIPTS=$ROOT/scripts/ci
DEV_REVERT_AFTER_SEC=3600 DEV_REVERT_WARN_SEC=900 key_prefix="" SUPERVISOR_THREAD=sup DISPATCH_THREAD=disp
mkdir -p "$STATE/sent" "$OUTBOX"; LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
git -C "$SRC" worktree add -q --detach "$TRUSTED" origin/main
eval "$(sed -n '/^review_jobs() {/p; /^review_list() {/,/^}/p; /^dev_round_noop() {/,/^}/p; /^dev_merge_only() {/,/^}/p; /^review_infra_reason() {/,/^}/p; /^run_verdict() {/,/^}/p; /^dev_verdict_run() {/,/^}/p; /^named_files() {/p; /^findings_cap() {/,/^}/p; /^findings() {/,/^}/p; /^notes_of() {/,/^}/p; /^findings_subset() {/,/^}/p; /^dev_main_split() {/,/^}/p; /^thread_of() /p; /^range_threads() {/,/^}/p' "$D")"
source "$ROOT/scripts/ci/review-machinery.sh"
for f in review_list findings findings_subset dev_main_split dev_verdict_run; do declare -F "$f" >/dev/null || fail "helper $f not extracted"; done
fixer_receipt_thread() { :; }
dev_blocked() { echo "dev_blocked $1" >> "$T/calls"; printf '%s\n' "$2" > "$T/routed"; printf '%s\n' "${6:-}" > "$T/routed-all"; }
wake_fixer() { echo "wake_fixer $1 $2" >> "$T/calls"; }
notify() { echo "notify $2" >> "$T/calls"; }; notify_best_effort() { notify "$@"; }; notify_attributed() { echo "notify_attributed $2" >> "$T/calls"; }
notify_threads() { echo "notify_threads $2" >> "$T/calls"; }
culprit_threads() { :; }; attribution() { :; }; fixer_phrase() { :; }; own_findings() { :; }; revert_after_for() { echo 3600; }
dispatch_msg() { printf 'x\n\nLoop: review-dispatch\nThread: disp\n'; }
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
  rm -f "$T/calls" "$T/routed" "$T/routed-all" "$LOG" "$STATE/open-findings.log" "$STATE/sent/"* "$STATE/dev.blocked_since"*; }
head_loop() { merged_one=0; DRY=""; ( cd "$ROOT" && eval "$loop" ) || fail "head loop failed"; g fetch -q origin; }
run_head_loop() { reset_dev; head_loop; }
run_train() { reset_dev; DRY=""; ( cd "$ROOT" && eval "$train" ) || fail "train failed"; g fetch -q origin; }
landed() { [ "$(g rev-parse origin/main)" != "$MAINSHA" ]; }
routed_nums() { sed -nE 's/^review-gate: BLOCKED #([0-9]+) .*/\1/p' "$T/routed" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
records() { if [ -f "$STATE/open-findings.log" ]; then grep -c 'pre-existing main finding' "$STATE/open-findings.log" || true; else echo 0; fi; }

# ── (a) only main findings (#1/#2, culprit C on main) ──
fixture_log "$T/log" "$C" 0; scenario
run_head_loop
! landed || fail "(a) a dev head blocked by main findings landed"
! grep -qE '^(dev_blocked|wake_fixer|notify)' "$T/calls" 2>/dev/null || fail "(a) a dev fixer / notice for main's findings: $(cat "$T/calls")"
test ! -e "$STATE/dev.blocked_since" || fail "(a) a dev block clock started for main's findings"
[ "$(records)" = 1 ] || fail "(a) main findings not recorded once: $(cat "$LOG" 2>/dev/null)"
grep -q "finding(s) 1 2 — culprit on main" "$STATE/open-findings.log" || fail "(a) record does not name #1 #2"
[ "$(grep -c '^review-gate: BLOCKED #[12] ' "$STATE/open-findings.log")" = 2 ] || fail "(a) the known-open feed lacks the BLOCKED lines"
head_loop; head_loop
[ "$(records)" = 1 ] || fail "(a) recorded again on later runs"
! grep -qE '^(dev_blocked|wake_fixer|notify)' "$T/calls" 2>/dev/null || fail "(a) later runs routed main's findings"
run_train
! landed || fail "(a) the train landed it"
! grep -qE '^(dev_blocked|wake_fixer|notify)' "$T/calls" 2>/dev/null || fail "(a) the train's blocked path routed main's findings: $(cat "$T/calls")"
[ "$(records)" = 1 ] || fail "(a) the train did not record main's findings once"
grep -E '^review-gate: BLOCKED' "$STATE/open-findings.log" | sed -E 's/^review-gate: BLOCKED (#[0-9]+ )?//' | grep -q '^regression \[should, security\]: The path-scoped preservation proof' \
  || fail "(a) known-open feed"
echo "ok - (a) only main findings: nothing routed, nothing landed, no clock; recorded once"

# ── (b) mixed: #1/#2 main + #3 the head's own ──
fixture_log "$T/log" "$C" 1; scenario
run_head_loop
grep -q "^dev_blocked $H" "$T/calls" || fail "(b) the dev finding was not routed"
[ "$(routed_nums)" = 3 ] || fail "(b) routed findings '$(routed_nums)', want only 3"
grep -q "commit=$H" "$T/routed" && ! grep -q "commit=$C" "$T/routed" || fail "(b) routed text carries main's findings"
grep -q "BLOCKED #1 " "$T/routed-all" && grep -q "BLOCKED #3 " "$T/routed-all" || fail "(b) dev_blocked did not get the full set (dupfix)"
test -s "$STATE/dev.blocked_since" || fail "(b) the dev finding started no block clock"
[ "$(records)" = 1 ] || fail "(b) main findings not recorded"
run_train
grep -q "^dev_blocked $H" "$T/calls" && [ "$(routed_nums)" = 3 ] || fail "(b) the train's blocked path routed '$(routed_nums)', want 3"
! landed || fail "(b) landed"
grep -q 'culprits_repaired "$s" "$(if \[ "$all" = "$f" \]' "$D" || fail "(b) dev_blocked's dupfix shortcut does not decide on the full set"
echo "ok - (b) mixed: only the dev finding routed; the dupfix shortcut sees the full set"

# ── (c) culprit not on main (D1) / "-" / abbreviated / no FINDING line: routed as before ──
for variant in dev dash abbrev nofinding; do
  if [ "$variant" = dev ]; then fixture_log "$T/log" "$D1" 0; else fixture_log "$T/log" "$C" 0; fi
  case $variant in
    dash) sed -i -E "s/FINDING #([12]) route=author commit=$C/FINDING #\1 route=author commit=-/" "$T/log" ;;
    abbrev) sed -i -E "s/FINDING #([12]) route=author commit=$C/FINDING #\1 route=author commit=${C:0:12}/" "$T/log" ;;
    nofinding) sed -i -E "/FINDING #[12] /d" "$T/log" ;;
  esac
  scenario; run_head_loop
  [ "$(routed_nums)" = "1 2" ] || fail "(c $variant) routed '$(routed_nums)', want 1 2"
  [ "$(records)" = 0 ] || { cat "$STATE/open-findings.log"; fail "(c $variant) recorded a dev finding as main's"; }
done
echo "ok - (c) culprit off main, '-', abbreviated, no FINDING line: routed as before"

# ── (d) overdue: the revert names only the dev findings' files (03f6fcd72 #1). #1/#2 name dev-review-base.sh, which the
#    dev commit D0 also touched; #3 names review-dispatch.sh ──
overdue() { reset_dev; echo $(( $(date +%s) - 7200 )) > "$STATE/dev.blocked_since"; echo "$H" > "$STATE/dev.blocked_since.sha"; head_loop; }
fixture_log "$T/log" "$C" 0; scenario; overdue
[ "$(g rev-parse origin/dev)" = "$H" ] || fail "(d) main's findings reverted dev: $(g log --oneline -1 origin/dev)"
! grep -q REVERTED "$LOG" 2>/dev/null || fail "(d) a revert for main's findings"
fixture_log "$T/log" "$C" 1; scenario; overdue
grep -q "REVERTED on dev" "$LOG" || fail "(d) the dev finding's overdue revert did not happen: $(cat "$LOG")"
rv=$(g log -1 --format=%B origin/dev)
grep -q "This reverts commit $D1" <<<"$rv" || fail "(d) the dev culprit was not reverted"
! grep -q "This reverts commit $D0" <<<"$rv" || fail "(d) main's findings named a file for the revert (D0 reverted)"
echo "ok - (d) main findings never reach the revert path; the dev finding's revert names only its own files"

# ── (e) a rerun of the same run with other findings (03f6fcd72 #2): attempt 1 had only main findings, attempt 2 only a new
#    dev finding → that dev finding is routed, nothing stale ──
fixture_log "$T/log" "$C" 0; scenario; run_head_loop
fixture_log "$T/log" "$D1" 0; sed -i -E '/FINDING #2 |BLOCKED #2 /d' "$T/log"; cp "$T/log" "$FX/log-$JID.txt"
head_loop
[ "$(routed_nums)" = 1 ] && grep -q "commit=$D1" "$T/routed" && ! grep -q "commit=$C" "$T/routed" || fail "(e) the rerun's dev finding was not routed alone: $(cat "$T/routed" 2>/dev/null)"
echo "ok - (e) a rerun is classified from its own findings"

# ── (f) the landing machinery is gone: no main-findings path in the contract scripts ──
! grep -nE 'REVIEW_MAIN_FINDINGS|REVIEW_APPROVAL|review-main-culprits|main-findings\)|record_approving_main|review_approve' \
    "$ROOT"/scripts/ci/review-passed.sh "$ROOT"/scripts/ci/merge-branch.sh "$ROOT"/scripts/ci/review-coverage.sh "$D" \
  || fail "(f) main-only landing machinery is still present"
test ! -e "$ROOT/scripts/ci/review-main-culprits.sh" || fail "(f) review-main-culprits.sh still exists"
echo "ok - (f) no main-only landing path"
echo "review-dispatch-main-culprit checks passed"
