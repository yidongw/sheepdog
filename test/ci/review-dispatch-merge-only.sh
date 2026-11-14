#!/usr/bin/env bash
# A dev round that cannot be blocked (11-13: vpn-sub 090c048d0, foxhole-backend 02b663bf0): dev beyond main holds only
# "merge main into dev" commits and the wrapper cancelled the round. The dispatcher took the cancelled run for a block —
# woke a "fixer", claimed the dev fixer slot, and an hour later sent "blocked > 60 min … nothing reverted". Runs the real
# final branch loop: a merge-only round or a run cancelled without a verdict is no block (no dev_blocked, no revert /
# overdue, block state cleared); a real block still is one.
set -euo pipefail
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }   # gh-cache.sh (the per-run memo of review-dispatch.sh): here the fake gh itself
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DEV=dev REPO=test/repo OUTBOX=$T/state/outbox TRUSTED=$T/trusted WORK=$T/work
DEV_REVERT_AFTER_SEC=3600 DEV_REVERT_WARN_SEC=900 key_prefix="" merged_one=1 SUPERVISOR_THREAD=import:claudeAgent:sup
mkdir -p "$STATE/sent" "$TRUSTED/scripts/ci" "$OUTBOX"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TRUSTED/scripts/ci/review-passed.sh"   # no round here passed
LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
eval "$(sed -n '/^dev_round_noop() {/,/^}/p; /^dev_merge_only() {/,/^}/p; /^review_infra_reason() {/,/^}/p; /^dev_infra_end() {/,/^}/p; /^run_verdict() {/,/^}/p; /^dev_verdict_run() {/,/^}/p; /^named_files() {/p' "$D")"
review_list() { gh run list -R "$REPO" -w review.yml -L "$1" --json "$2" -q "$3"; }   # this fake gh answers lists pre-filtered
loop=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('\nnow=$(date +%s)\nfor ref in ') + 1
print(s[a:s.index('\ndone\n', a) + 6])
PY
)
# stubs: what the block path would do
dev_blocked() { echo "dev_blocked $1" >> "$T/calls"; }
notify_attributed() { echo "notify_attributed $2" >> "$T/calls"; }
notify() { echo "notify $2" >> "$T/calls"; notify_outcome=sent; }
notify_best_effort() { notify "$@"; }
findings() { echo "review-gate: BLOCKED #1 regression [should]: x"; }
culprit_threads() { :; }; attribution() { :; }; fixer_phrase() { :; }; own_findings() { :; }; revert_after_for() { echo 3600; }
RUNS=""; JOBS='{"jobs":[]}'; declare -A JOBS_OF=()   # RUNS: "<id> <status> <conclusion>" lines, newest first
gh() { local id j; case "$*" in
  "run list"*) printf '%s\n' "$RUNS" ;;
  *jobs*) id=$(grep -oE 'runs/[0-9]+' <<<"$*" | cut -d/ -f2); j=${JOBS_OF[$id]:-$JOBS}; jq -r "${4:-.}" <<<"$j" 2>/dev/null || echo "$j" ;;
  *) echo '{}' ;; esac; }
git init -q --bare "$T/remote.git"; git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
c() { echo "$RANDOM" >> "$SRC/$1"; g add "$1"; g commit -q -m "$2"; g rev-parse HEAD; }
c a "base" >/dev/null; g push -q origin HEAD:refs/heads/main
c h "Hotfix: h" >/dev/null; g push -q origin HEAD:refs/heads/main
# dev = main + one "merge main into dev" commit, nothing else
MERGEONLY=$(git -C "$SRC" -c user.name=t -c user.email=t@t commit-tree "$(g rev-parse 'main^{tree}')" -p "$(g rev-parse main)" -p "$(g rev-parse main~1)" -m "merge main into dev")
g push -q -f origin "$MERGEONLY:refs/heads/dev"; g fetch -q origin
test -z "$(g rev-list --no-merges origin/main..origin/dev)" || fail "setup: dev is not merge-only"
prime() { rm -f "$T/calls" "$STATE/sent/"*; JOBS_OF=(); echo $(( $(date +%s) - 4000 )) > "$STATE/dev.blocked_since"; echo "$1" > "$STATE/dev.blocked_since.sha"; echo "$1" > "$STATE/dev-fixer.active"; rm -rf "$OUTBOX"; mkdir -p "$OUTBOX/$1"; touch "$OUTBOX/$1/x"; }

# 1. merge-only dev, its run cancelled by the wrapper (no job failed) → no block at all; the block state is cleared
prime "$MERGEONLY"; touch "$STATE/sent/$MERGEONLY.fixer-blocked"   # the wrapper's empty marker
RUNS="77 completed cancelled"; JOBS='{"jobs":[{"name":"tests","conclusion":"cancelled"},{"name":"review","conclusion":"cancelled"}]}'
eval "$loop"
if grep -q '^dev_blocked' "$T/calls" 2>/dev/null; then fail "a cancelled merge-only round was treated as blocked (fixer woken)"; fi
if grep -q 'overdue' "$T/calls" 2>/dev/null; then fail "a cancelled merge-only round got an overdue notice"; fi
test ! -e "$STATE/dev.blocked_since" || fail "the block clock of a merge-only round was kept"
test ! -e "$STATE/dev-fixer.active" || fail "a merge-only round still claims the dev fixer slot"
test -e "$OUTBOX/$MERGEONLY/x" || fail "queued notices were deleted (re-check of 379550c9a #1: only the outbox flush retires them)"
grep -q "not blocked — only merges beyond main" "$LOG"
echo 'merge-only round: never blocked, state cleared'

# 2. a merge-only round whose run even concluded failure is no block either
prime "$MERGEONLY"; RUNS="78 completed failure"; JOBS='{"jobs":[{"name":"tests","conclusion":"failure"}]}'
eval "$loop"
if grep -q '^dev_blocked' "$T/calls" 2>/dev/null; then fail "a failed merge-only round was treated as blocked"; fi

# 3. real dev work: a run cancelled without a verdict is no block; a real review failure still is
g checkout -q -B devr main; R=$(c r "real dev work"); g push -q -f origin "$R:refs/heads/dev"; g fetch -q origin
prime "$R"; RUNS="79 completed cancelled"; JOBS='{"jobs":[{"name":"tests","conclusion":"cancelled"},{"name":"review","conclusion":"cancelled"}]}'
eval "$loop"
if grep -q '^dev_blocked' "$T/calls" 2>/dev/null; then fail "a run cancelled without a verdict was treated as blocked"; fi
prime "$R"; RUNS="80 completed failure"; JOBS='{"jobs":[{"name":"tests","conclusion":"success"},{"name":"review","conclusion":"failure"}]}'
eval "$loop"
grep -q "^dev_blocked $R" "$T/calls" || fail "a real dev block is no longer handled"
# the dispatcher's own cancel after a blocked review (review failure, run cancelled) is still a block
prime "$R"; RUNS="81 completed cancelled"; JOBS='{"jobs":[{"name":"tests","conclusion":"cancelled"},{"name":"review","conclusion":"failure"}]}'
eval "$loop"
grep -q "^dev_blocked $R" "$T/calls" || fail "a blocked review whose tests were cancelled is no longer a block"
echo 'real blocks still blocked; verdict-less cancels are not'

# re-check of 379550c9a #1: an earlier GENUINE failure of the same sha survives a later cancelled rerun — the block path
# goes on with that run, and its undelivered escalation stays queued
prime "$R"; touch "$STATE/sent/$R.reverted"
RUNS=$'92 completed cancelled\n90 completed failure'
JOBS_OF[92]='{"jobs":[{"name":"tests","conclusion":"cancelled"},{"name":"review","conclusion":"cancelled"}]}'
JOBS_OF[90]='{"jobs":[{"name":"tests","conclusion":"success"},{"name":"review","conclusion":"failure"}]}'
eval "$loop"
grep -q "^dev_blocked $R" "$T/calls" || fail "a cancelled rerun hid the earlier genuine failure of the same sha"
test -e "$OUTBOX/$R/x" || fail "an undelivered escalation of the genuine failure was deleted"
test -s "$STATE/dev.blocked_since" || fail "the genuine block's episode was ended by a cancelled rerun"
echo 'cancelled rerun: the earlier genuine failure stands, its notices stay queued'

# re-check #2: a historical merge-only sha never resets the dev HEAD's block episode
prime "$R"; before=$(cat "$STATE/dev.blocked_since")
dev_round_noop "$MERGEONLY" 1 failure          # the merge-train path (no "clear")
dev_round_noop "$MERGEONLY" 1 failure clear    # even with clear: origin/dev is $R, not this historical sha
test "$(cat "$STATE/dev.blocked_since" 2>/dev/null)" = "$before" || fail "a historical merge-only sha reset the head's block timer"
test "$(cat "$STATE/dev-fixer.active")" = "$R" || fail "a historical merge-only sha freed the head's fixer slot"
echo 'historical merge-only shas leave the head episode alone'

# re-check #3: an "evil" merge (no non-merge commit, but the merge changes code) — its failed review is a block
EVIL=$(git -C "$SRC" -c user.name=t -c user.email=t@t commit-tree "$(cd "$SRC" && g checkout -q --detach main && echo evil >> a && g add a && g write-tree && g reset -q --hard main)" -p "$(g rev-parse main)" -p "$(g rev-parse main~1)" -m "merge main into dev (conflict resolved)")
g push -q -f origin "$EVIL:refs/heads/dev"; g fetch -q origin
test -z "$(g rev-list --no-merges origin/main..origin/dev)" || fail "setup: the evil merge has a non-merge commit"
prime "$EVIL"; RUNS="93 completed failure"; JOBS_OF[93]='{"jobs":[{"name":"tests","conclusion":"success"},{"name":"review","conclusion":"failure"}]}'
eval "$loop"
grep -q "^dev_blocked $EVIL" "$T/calls" || fail "a failed review of a merge that changes code was suppressed as merge-only"
echo 'a code-changing merge is not merge-only'

# 10efcf9a9 #1/#2: failed merge A -> tree-equal replacement B -> unrelated ordinary commit C.
# B ends A's expired dev-wide episode, so C gets its own full repair window instead of an immediate real revert push.
prime "$EVIL"; RUNS="94 completed failure"
eval "$loop"
grep -q "^dev_blocked $EVIL" "$T/calls" || fail "setup: merge A was not blocked"
REPLACEMENT=$(g commit-tree "$(g rev-parse 'main^{tree}')" -p "$EVIL" -p "$(g rev-parse main~1)" -m "merge restoring main's tree")
g push -q origin "$REPLACEMENT:refs/heads/dev"; g fetch -q origin
dev_merge_only "$REPLACEMENT" || fail "setup: replacement B is not merge-only"
dev_round_noop "$REPLACEMENT" 95 failure       # inspecting even the current sha without clear decides no episode
test "$(cat "$STATE/dev.blocked_since.sha")" = "$EVIL" || fail "an inspection ended the dev block episode"
RUNS="95 completed failure"
eval "$loop"
replacement_clock=$(cat "$STATE/dev.blocked_since" 2>/dev/null || true)
replacement_owner=$(cat "$STATE/dev.blocked_since.sha" 2>/dev/null || true)
test -e "$OUTBOX/$EVIL/x" || fail "replacement B deleted A's queued notices"
test "$(cat "$STATE/dev-fixer.active")" = "$EVIL" || fail "replacement B freed A's fixer slot"
g checkout -q --detach "$REPLACEMENT"; LATER=$(c later.ts "unrelated ordinary work")
g push -q origin "$LATER:refs/heads/dev"; g fetch -q origin
findings() { echo 'review-gate: BLOCKED #1 regression [should]: later.ts needs a fix'; }
# These helpers are only used if the production loop actually builds and pushes a revert to our local bare remote.
thread_of() { :; }; dispatch_msg() { printf 'subject\n\nfixture revert\n'; }
RUNS="96 completed failure"; started=$(date +%s)
eval "$loop"
test "$(g ls-remote origin refs/heads/dev | cut -f1)" = "$LATER" || fail "C's first failed review automatically reverted unrelated work using A's expired clock"
test -z "$replacement_clock$replacement_owner" || fail "replacement B retained A's block clock or owner"
test "$(cat "$STATE/dev.blocked_since.sha")" = "$LATER" || fail "C did not own its new block episode"
test "$(cat "$STATE/dev.blocked_since")" -ge "$started" || fail "C inherited an old block clock"
test -e "$OUTBOX/$EVIL/x" || fail "C's review deleted A's queued notices"
echo 'replacement merge ends the old episode; later work gets a fresh clock and no automatic revert'

# 4. the merge-train's blocked path asks the same question
grep -q '&& ! dev_round_noop "$bsha" "$brid" failure; then' "$D" || fail "the merge-train blocked path does not skip merge-only rounds"
echo 'merge-only checks passed'
