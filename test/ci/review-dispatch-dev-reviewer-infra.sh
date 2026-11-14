#!/usr/bin/env bash
# A dev review whose REVIEWER did not run is infrastructure, not a finding (tralyx dev 9ef7d5d06, 11-14: "review-gate:
# reviewer failed: spawn E2BIG" — the prompt went through argv past MAX_ARG_STRLEN — was treated as a block: a fixer was
# woken, found nothing to fix, "fix failed" went to the supervisor and the dev auto-revert clock started). Runs the real dev
# merge-train block scan and the real final branch loop:
#   · no dev_blocked (no fixer, no author notice), dev.blocked_since not started, no revert / overdue;
#   · the supervisor hears once per failed review attempt (run + review job id; a rerun is a new job), never again on later
#     scans (train scan + head loop, repeated ticks, a historical verdict next to it); undelivered → retried;
#   · control: findings, failed trusted tests or gates errors next to it keep the block path.
set -euo pipefail
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DEV=dev REPO=test/repo OUTBOX=$T/state/outbox TRUSTED=$T/trusted WORK=$T/work
DEV_REVERT_AFTER_SEC=3600 DEV_REVERT_WARN_SEC=900 key_prefix="" merged_one=1 CI_SCRIPTS=scripts/ci
SUPERVISOR_THREAD=import:claudeAgent:sup DISPATCH_THREAD=mcp:77777777-7777-7777-7777-777777777777
mkdir -p "$STATE/sent" "$TRUSTED/scripts/ci" "$OUTBOX"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TRUSTED/scripts/ci/review-passed.sh"   # no round here passed
LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
fns() { local n; for n in "$@"; do sed -n "/^$n() {/,/^}/p; /^$n() { .*}\$/p" "$D"; done; }
eval "$(fns dev_round_noop dev_merge_only run_verdict dev_verdict_run named_files review_infra_reason dev_infra infra_alert dev_split_main main_culprit_hint findings_subset)"
for f in review_infra_reason dev_infra infra_alert; do declare -F "$f" >/dev/null || fail "missing $f"; done
review_list() { gh run list -R "$REPO" -w review.yml -L "$1" --json "$2" -q "$3"; }
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
a = s.index('  bl=$(review_list 100 databaseId,displayTitle,status,conclusion')
print(s[a:s.index('\n  for tsha in ', a)])
PY
)
[ -n "$train" ] && [ -n "$loop" ] || fail "setup: loop sections not found"
# stubs: what the block path would do
dev_blocked() { echo "dev_blocked $1" >> "$T/calls"; }
notify_attributed() { echo "notify_attributed $2" >> "$T/calls"; }
UNDELIVERED=""
notify() { if [ -e "$STATE/sent/$1.$2" ]; then notify_outcome=dup; return 0; fi
  if [ -n "$UNDELIVERED" ]; then UNDELIVERED=""; echo "$1 $2" >> "$T/attempts"; notify_outcome=undelivered; return 1; fi
  echo "notify $1 $2 $3" >> "$T/calls"; printf '%s\n' "$4" > "$T/msg-$2"; notify_outcome=sent; touch "$STATE/sent/$1.$2"; }
notify_best_effort() { notify "$@" || :; }
culprit_threads() { :; }; attribution() { :; }; fixer_phrase() { :; }; own_findings() { :; }; revert_after_for() { echo 3600; }
declare -A FIND_OF=()
findings() { printf '%s\n' "${FIND_OF[$1]:-}"; }
RUNS=""; declare -A JOBS_OF=()   # RUNS: "<id> <status> <conclusion>" lines, newest first (the head loop's listing)
TRAIN=""   # the train scan's listing: "<id> review <sha>" lines (completed failures)
gh() { local id j; case "$*" in
  "run list"*"\"\\(.databaseId) \\(.displayTitle)\""*) printf '%s\n' "$TRAIN" ;;
  "run list"*) printf '%s\n' "$RUNS" ;;
  *jobs*) id=$(grep -oE 'runs/[0-9]+' <<<"$*" | cut -d/ -f2); j=${JOBS_OF[$id]:-'{"jobs":[]}'}; jq -r "${4:-.}" <<<"$j" 2>/dev/null || echo "$j" ;;
  *) echo '{}' ;; esac; }
git init -q --bare "$T/remote.git"; git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
c() { mkdir -p "$SRC/$(dirname "$1")"; echo "$RANDOM" >> "$SRC/$1"; g add "$1"; g commit -q -m "$2" -m "Thread: mcp:11111111-1111-1111-1111-111111111111"; g rev-parse HEAD; }
c a base >/dev/null; g push -q origin HEAD:refs/heads/main
g checkout -q -b devw; S1=$(c src/x.ts "dev work 1"); g push -q -f origin "$S1:refs/heads/dev"; g fetch -q origin
calls() { cat "$T/calls" 2>/dev/null || true; }
n_notices() { grep -c '^notify .* infra\.dev' "$T/calls" 2>/dev/null || echo 0; }
FAILJOBS='{"jobs":[{"name":"tests","conclusion":"success"},{"name":"review","id":1,"conclusion":"failure"}]}'
failjobs() { jq -c --argjson id "$1" '.jobs[1].id = $id' <<<"$FAILJOBS"; }   # failjobs <review job id>
E2BIG=$'review-gate: reviewer failed: spawn E2BIG'

# 0. the classifier: only a reviewer failure with no finding / failed test / gates error
review_infra_reason "$E2BIG" >/dev/null || fail "reviewer failed: not infra"
test "$(review_infra_reason "$E2BIG")" = "reviewer failed: spawn E2BIG" || fail "the reason: $(review_infra_reason "$E2BIG")"
review_infra_reason "review-gate: reviewer timed out: codex timed out after 3600000ms" >/dev/null || fail "timeout: not infra"
review_infra_reason "review-gate: no parseable VERDICT line (not a pass). Reviewer output tail:" >/dev/null || fail "no verdict: not infra"
for t in "$E2BIG"$'\ntrusted tests job: failure' "$E2BIG"$'\nreview-gate: BLOCKED #1 regression [should]: x' "[gates abc ERROR] missing Verify:"$'\n'"$E2BIG" "review-gate: BLOCKED #1 regression [should]: x" ""; do
  if review_infra_reason "$t" >/dev/null; then fail "classified as infrastructure: $t"; fi
done
echo 'classifier: reviewer failures only, never next to a finding, failed tests or gates errors'

# 1. the dev head's review: reviewer failed → no block, no clock, supervisor once (head loop and train scan agree)
RUNS="101 completed failure"; JOBS_OF[101]=$(failjobs 1011); FIND_OF[101]=$E2BIG; TRAIN="101 review $S1"
eval "$train"; eval "$loop"; eval "$train"; eval "$loop"
if grep -q '^dev_blocked' "$T/calls" 2>/dev/null; then fail "a reviewer failure was treated as a dev block (fixer / authors): $(calls)"; fi
if grep -q 'overdue\|revert' "$T/calls" 2>/dev/null; then fail "a revert / overdue path ran: $(calls)"; fi
test ! -e "$STATE/dev.blocked_since" || fail "the revert clock started for a reviewer failure"
test "$(n_notices)" = 1 && grep -q "^notify $S1 infra\.dev\.101\.1011 $SUPERVISOR_THREAD$" "$T/calls" || fail "not one supervisor notice: $(calls)"
m=$T/msg-infra.dev.101.1011
grep -q 'reviewer failed: spawn E2BIG' "$m" && grep -q 'gh run rerun 101 -R test/repo --failed' "$m" || fail "the notice: $(cat "$m")"
test "$(grep -c "review run 101 (job 1011)" "$LOG")" = 1 || fail "not logged once: $(cat "$LOG")"
echo 'dev reviewer failure: no block, no clock, no fixer; the supervisor once with the rerun command'

# 2. an old block clock is left alone (this round decides nothing), and still no revert fires for this head
past=$(( $(date +%s) - 7200 )); echo "$past" > "$STATE/dev.blocked_since"; echo "$S1" > "$STATE/dev.blocked_since.sha"
eval "$loop"
test "$(cat "$STATE/dev.blocked_since")" = "$past" || fail "a reviewer failure changed the block clock"
test ! -e "$STATE/sent/$S1.reverted" || fail "the overdue clock reverted on a reviewer failure"
rm -f "$STATE/dev.blocked_since" "$STATE/dev.blocked_since.sha"
echo 'an existing clock is neither started, cleared nor acted on'

# 3. the rerun of the same run fails again (a new review job): one more notice — the head is still unreviewed; then quiet
JOBS_OF[101]=$(failjobs 1012)
eval "$train"; eval "$loop"; eval "$train"; eval "$loop"
test "$(n_notices)" = 2 && grep -q "^notify $S1 infra\.dev\.101\.1012 " "$T/calls" || fail "a failed rerun was not told once: $(calls)"
echo 'a failed rerun: its own notice, once'

# 4. (reviews of 301053acd #3) a later head failing while a historical head's verdict is listed too: repeated ticks never
#    re-notify; the later head's attempt is told once
S2=$(c src/y.ts "dev work 2"); g push -q -f origin "$S2:refs/heads/dev"; g fetch -q origin
RUNS="102 completed failure"; JOBS_OF[102]=$(failjobs 1021); FIND_OF[102]=$E2BIG
FIND_OF[99]='review-gate: BLOCKED #1 regression [should]: src/x.ts x'
for tick in 1 2 3; do TRAIN=$'99 review '"$S1"; eval "$train"; TRAIN=$'102 review '"$S2"$'\n99 review '"$S1"; eval "$train"; eval "$loop"; done
test "$(n_notices)" = 3 && grep -q "^notify $S2 infra\.dev\.102\.1021 " "$T/calls" || fail "repeated ticks: $(calls)"
if grep -q "^dev_blocked $S2" "$T/calls"; then fail "the infra head was blocked"; fi
grep -q "^dev_blocked $S1" "$T/calls" || fail "control: the historical verdict is no longer a block"
echo 'repeated ticks with a historical verdict: no repeat, the new attempt once'

# 5. the reviewer is fixed, the rerun reviews and blocks with findings → the block path runs as before
FIND_OF[102]='review-gate: BLOCKED #1 regression [should]: src/y.ts drops rows'
eval "$loop"
grep -q "^dev_blocked $S2" "$T/calls" || fail "a real verdict is not a block: $(calls)"
test -s "$STATE/dev.blocked_since" || fail "the real block did not start its clock"
rm -f "$STATE/dev.blocked_since" "$STATE/dev.blocked_since.sha"
echo 'real findings still block'

# 6. an undelivered alert is retried on the next run, then once
S3=$(c src/z.ts "dev work 3"); g push -q -f origin "$S3:refs/heads/dev"; g fetch -q origin
RUNS="103 completed failure"; JOBS_OF[103]=$(failjobs 1031); FIND_OF[103]="review-gate: reviewer timed out: codex timed out after 3600000ms"; TRAIN=""
UNDELIVERED=1; eval "$loop"
test "$(n_notices)" = 3 && test "$(wc -l < "$T/attempts")" = 1 || fail "setup: the undelivered attempt: $(calls)"
eval "$loop"
test "$(n_notices)" = 4 && grep -q "^notify $S3 infra\.dev\.103\.1031 " "$T/calls" || fail "the undelivered alert was not retried: $(calls)"
eval "$loop"; test "$(n_notices)" = 4 || fail "the delivered alert repeated"
echo 'undelivered alert: retried, then once'

# 7. control: the reviewer failure next to failed trusted tests is a block (the tests are a finding)
S4=$(c src/w.ts "dev work 4"); g push -q -f origin "$S4:refs/heads/dev"; g fetch -q origin
RUNS="104 completed failure"; JOBS_OF[104]=$(failjobs 1041); FIND_OF[104]="$E2BIG"$'\ntrusted tests job: failure'
eval "$loop"
grep -q "^dev_blocked $S4" "$T/calls" || fail "failed tests next to a reviewer failure are no longer a block: $(calls)"
echo 'control: failed tests next to it still block'
echo 'dev reviewer-infrastructure checks passed'
