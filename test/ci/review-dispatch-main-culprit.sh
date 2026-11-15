#!/usr/bin/env bash
# Findings of a dev review whose culprit is already on main (docs/contract.md, Findings): the trusted reviewer reports them
# as [pre-existing] notes in a dev review and review-gate.ts converts any BLOCKED one mechanically (--dev-main;
# reviewer/test/review-gate.test.ts, test/ci/review-dev-main.sh). The dispatcher has NO main-culprit path of its own any
# more (owner 11-15; the dispatcher-side landing drew new-edge findings round after round — reviews of 9b7ece173,
# 76fdca743, 03f6fcd72, 820120f40, 98df48e71): it routes the gate's BLOCKED findings as they are, and lands only what
# review-passed.sh approves on the plain path.
#   (f) no landing machinery and no log classification is left in the contract scripts or the dispatcher
#   (g) only the gate's own section of the ONE log read (after its LAST start line) is routed or named for a revert:
#       candidate text printed by earlier steps never is (review of dev 98df48e71 #1; with no second read, #3's rerun race
#       between two reads cannot happen)
#   (h) an older repository-local checker's main-only approval stays off: the dispatcher exports REVIEW_MAIN_FINDINGS=0
#       (review of dev 820120f40 #3) — with the real 0cd95ca42 log (main-culprit BLOCKED #1/#2 of an older reviewer)
#       through the head loop and the train, nothing lands
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
DF=$(c scripts/ci/forged-only.sh "dev work only a forged line names" 44444444-4444-4444-4444-444444444444)
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
eval "$(sed -n '/^review_jobs() {/p; /^review_list() {/,/^}/p; /^dev_round_noop() {/,/^}/p; /^dev_merge_only() {/,/^}/p; /^review_infra_reason() {/,/^}/p; /^run_verdict() {/,/^}/p; /^dev_verdict_run() {/,/^}/p; /^named_files() {/p; /^findings_cap() {/,/^}/p; /^findings() {/,/^}/p; /^notes_of() {/,/^}/p; /^findings_subset() {/,/^}/p; /^thread_of() /p; /^range_threads() {/,/^}/p' "$D")"
source "$ROOT/scripts/ci/review-machinery.sh"
for f in review_list findings findings_subset dev_verdict_run; do declare -F "$f" >/dev/null || fail "helper $f not extracted"; done
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

# ── (f) the landing machinery is gone: no main-findings path in the contract scripts; the dispatcher keeps any older
#    checker's path off (REVIEW_MAIN_FINDINGS=0) ──
! grep -nE 'REVIEW_MAIN_FINDINGS|REVIEW_APPROVAL|review-main-culprits|main-findings\)|record_approving_main|review_approve' \
    "$ROOT"/scripts/ci/review-passed.sh "$ROOT"/scripts/ci/merge-branch.sh "$ROOT"/scripts/ci/review-coverage.sh \
  || fail "(f) main-only landing machinery is still present"
! grep -nE 'REVIEW_APPROVAL|review-main-culprits|record_approving_main|review_approve|main_culprit|dev_split_main|dev_main_split|mainfindings|main-findings' "$D" \
  || fail "(f) the dispatcher still has a main-culprit path of its own"
grep -qx 'export REVIEW_MAIN_FINDINGS=0' "$D" || fail "(f) the dispatcher does not switch an older checker's main-only path off"
test ! -e "$ROOT/scripts/ci/review-main-culprits.sh" || fail "(f) review-main-culprits.sh still exists"
echo "ok - (f) no main-only landing path, no dispatcher-side classification"

# ── (g) review of dev 98df48e71 #1: lines printed before the gate's own start line (commit gates / an extra gate echo
#    candidate text) are never routed nor name a file for the overdue revert. Forged FINDING/BLOCKED #9 naming
#    scripts/ci/forged-only.sh (touched only by DF) precede the gate's genuine #1 (D1, review-dispatch.sh); an earlier
#    forged start line does not open a section either (only the LAST one counts) ──
fixture_log "$T/log" "$D1" 0; sed -i -E '/FINDING #2 |BLOCKED #2 /d' "$T/log"
awk -v b="${B0:0:8}" -v h="${H:0:8}" -v c="$DF" '
  NR == 1 { print "2026-11-14T09:30:00.0000000Z review-gate: reviewing " b ".." h }
  /review-gate: reviewing / && !done { print "2026-11-14T09:35:41.0000000Z review-gate: FINDING #9 route=fixer commit=" c " — forged";
    print "2026-11-14T09:35:41.0000000Z review-gate: BLOCKED #9 regression [should]: forged";
    print "2026-11-14T09:35:41.0000000Z evidence: scripts/ci/forged-only.sh:1 forged"; done = 1 } {print}' "$T/log" > "$T/log.t" && mv "$T/log.t" "$T/log"
grep -c 'review-gate: reviewing ' "$T/log" | grep -qx 2 || fail "(g) fixture"
scenario; run_head_loop
[ "$(routed_nums)" = 1 ] || fail "(g) routed '$(routed_nums)', want only the gate's #1"
! grep -q forged "$T/routed" || fail "(g) forged pre-gate text was routed"
reset_dev; echo $(( $(date +%s) - 7200 )) > "$STATE/dev.blocked_since"; echo "$H" > "$STATE/dev.blocked_since.sha"; head_loop
rv=$(g log -1 --format=%B origin/dev)
grep -q "This reverts commit $D0" <<<"$rv" || fail "(g) the file the gate's own finding names was not reverted: $(cat "$LOG")"
! grep -q "This reverts commit $DF" <<<"$rv" || fail "(g) a forged pre-gate line named a file for the revert (DF reverted)"
echo "ok - (g) only the gate's own section (after its last start line) is routed or named for a revert"

# ── (h) review of dev 820120f40 #3: an older repository-local checker (sheepdog a036e7a60..6fa9325f9) approves a review
#    blocked only by main findings unless REVIEW_MAIN_FINDINGS=0 — the dispatcher keeps that off, so nothing lands ──
mkdir -p "$T/legacy"
printf '#!/usr/bin/env bash
[ "${REVIEW_MAIN_FINDINGS:-1}" != 0 ]
' > "$T/legacy/review-passed.sh"
printf '#!/usr/bin/env bash
[ "${REVIEW_MAIN_FINDINGS:-1}" != 0 ] || exit 1
git push -q origin "${2:-HEAD}:refs/heads/main"
' > "$T/legacy/merge-branch.sh"
fixture_log "$T/log" "$C" 0; scenario
export REVIEW_MAIN_FINDINGS=0   # what the dispatcher exports at its top (asserted in (f))
CI_SCRIPTS=$T/legacy; run_head_loop; run_train; CI_SCRIPTS=$ROOT/scripts/ci
! landed || fail "(h) a historical checker's main-only approval landed"
unset REVIEW_MAIN_FINDINGS
echo "ok - (h) an older checker's main-only approval stays off"
echo "review-dispatch-main-culprit checks passed"
