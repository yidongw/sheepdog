#!/usr/bin/env bash
# Dispatcher wakes only the authors whose commits touch the files a finding / conflict names (owner 11-11).
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
# Any command that is not found — a dispatcher helper the test did not extract — fails the whole test at once, even
# inside an if / || condition (review of 02828988f #7: "culprits_repaired: command not found" printed, test exited 0).
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
eval "$(sed -n '/^thread_of() /p; /^fixer_receipt_thread() {/,/^}/p; /^range_threads() {/,/^}/p; /^culprit_threads() {/,/^}/p; /^notify_threads() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in thread_of fixer_receipt_thread range_threads culprit_threads notify_threads; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT
MAIN=main
git -C "$SRC" init -q -b main
git -C "$SRC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$SRC" update-ref refs/remotes/origin/main HEAD
commit() { # commit <file> <thread>
  mkdir -p "$SRC/$(dirname "$1")"; echo "$RANDOM" >> "$SRC/$1"; git -C "$SRC" add "$1"
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -m "change $1" -m "Thread: $2"
}
commit src/lib/a.ts mcp:11111111-1111-1111-1111-111111111111
commit src/smartmoney/b.ts mcp:22222222-2222-2222-2222-222222222222
commit test/b.test.ts mcp:22222222-2222-2222-2222-222222222222
head=$(git -C "$SRC" rev-parse HEAD)

# a finding naming b.ts → only its author
out=$(culprit_threads "$head" "review-gate: BLOCKED ... evidence: src/smartmoney/b.ts:12 does X; test/b.test.ts:3")
test "$out" = "mcp:22222222-2222-2222-2222-222222222222"
# a conflict list naming a.ts → only its author
out=$(culprit_threads "$head" $'src/lib/a.ts')
test "$out" = "mcp:11111111-1111-1111-1111-111111111111"
# no file named, or none matched → nobody (owner 11-12: never broadcast to every range author; callers use the supervisor)
test -z "$(culprit_threads "$head" "narrative-version gate failed")"
test -z "$(culprit_threads "$head" "src/elsewhere/z.ts:1")"
eval "$(sed -n '/^or_supervisor() /p' scripts/ci/review-dispatch.sh)"; for _f in or_supervisor; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done; SUPERVISOR_THREAD=sup
test "$(or_supervisor "$(culprit_threads "$head" "src/elsewhere/z.ts:1")")" = sup

# notify_threads sends one keyed notice per thread
sent=()
notify_best_effort() { sent+=("$2 $3"); }
key_prefix=""
notify_threads "$head" blocked "$(culprit_threads "$head" "src/smartmoney/b.ts")" msg
test "${#sent[@]}" -eq 1
test "${sent[0]}" = "blocked.0 mcp:22222222-2222-2222-2222-222222222222"
echo 'culprit routing checks passed'

# fixer_at_work: a receipt alone is not a fixer at work (review of da9021d4c)
eval "$(sed -n '/^devfix_fix_of() {/,/^}/p; /^fixer_at_work() {/,/^}/p; /^fixer_thread_state() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in devfix_fix_of fixer_at_work fixer_thread_state; do declare -F "$_f" >/dev/null || { echo "missing helper $_f" >&2; exit 1; }; done
R=$(mktemp -d); trap 'rm -rf "$SRC" "$R"' EXIT
STATE=$R; mkdir -p "$R/sent"
t3_status=running
timeout() { shift; "$@"; }
t3() { printf '%s %s\n' "$3" "$t3_status"; }   # `t3 thread show <tid>` → "<tid> <status>"
if fixer_at_work "$R/none"; then echo "unexpected: fixer_at_work "$R/none"" >&2; exit 1; fi                                   # no receipt
echo "mcp:aaaa" > "$R/rec"
fixer_at_work "$R/rec"                                      # thread still running
t3_status=completed
if fixer_at_work "$R/rec"; then echo "unexpected: fixer_at_work "$R/rec"" >&2; exit 1; fi                                    # it ended: tell the authors
git -C "$SRC" update-ref "refs/remotes/origin/devfix/${head:0:12}" "$head"
if fixer_at_work "$R/rec" "devfix/${head:0:12}"; then echo "unexpected: an unlandable devfix (no Review-Fix-Of) counted as delivered" >&2; exit 1; fi
# abbreviated trailer: the landing step requires the full 40-hex sha → not on its way
git -C "$SRC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix short" -m "Review-Fix-Of: ${head:0:9}"
git -C "$SRC" update-ref "refs/remotes/origin/devfix/${head:0:12}" HEAD
if fixer_at_work "$R/rec" "devfix/${head:0:12}"; then echo "unexpected: an abbreviated Review-Fix-Of counted as landable" >&2; exit 1; fi
# a tip with the trailer over a fix commit without it: landing rejects every-commit violations → not on its way
git -C "$SRC" reset -q --hard "$head"
git -C "$SRC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "untrailed fix"
git -C "$SRC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix tip" -m "Review-Fix-Of: $head"
git -C "$SRC" update-ref "refs/remotes/origin/devfix/${head:0:12}" HEAD
if fixer_at_work "$R/rec" "devfix/${head:0:12}"; then echo "unexpected: a fix commit without Review-Fix-Of counted as landable" >&2; exit 1; fi
git -C "$SRC" reset -q --hard "$head"
git -C "$SRC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix" -m "Review-Fix-Of: $head"
git -C "$SRC" update-ref refs/remotes/origin/devfix/abc HEAD
if fixer_at_work "$R/rec" devfix/abc; then echo "unexpected: an ended fixer with a landable branch suppressed authors" >&2; exit 1; fi
# A branch may fail trusted tests; only a live fixer owns the hand-off.
t3_status=running
fixer_at_work "$R/rec" devfix/abc
t3_status=completed
GIT_COMMITTER_DATE="@$(( $(date +%s) - 10800 )) +0000" git -C "$SRC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "old fix" -m "Review-Fix-Of: $head"
git -C "$SRC" update-ref "refs/remotes/origin/devfix/${head:0:12}" HEAD
if fixer_at_work "$R/rec" "devfix/${head:0:12}"; then echo "unexpected: a 3 h old devfix with an ended fixer counted as delivered" >&2; exit 1; fi
# a FUTURE-dated tip with an ended fixer and a 2 h old receipt: never fresh (review of e46c931f4)
GIT_COMMITTER_DATE="@2000000000 +0000" git -C "$SRC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "future fix" -m "Review-Fix-Of: $head"
git -C "$SRC" update-ref "refs/remotes/origin/devfix/${head:0:12}" HEAD
touch -d '2 hours ago' "$R/rec"; t3_status=completed
if fixer_at_work "$R/rec" "devfix/${head:0:12}"; then echo "unexpected: a future-dated devfix counted as fresh" >&2; exit 1; fi
touch "$R/rec"
if fixer_at_work "$R/rec" "devfix/${head:0:12}"; then echo "unexpected: a future-dated devfix counted as fresh with a fresh receipt" >&2; exit 1; fi
t3_status=preparing
fixer_at_work "$R/rec"                                      # a fixer still preparing its workspace is at work
touch -d '2 hours ago' "$R/rec"; t3_status=running
if fixer_at_work "$R/rec"; then echo "unexpected: fixer_at_work "$R/rec"" >&2; exit 1; fi                                    # past the 60 min hand-off window
# review of c0183dbbf #1: a just-launched fixer T3 does not find yet is still at work (not "ended → tell the authors")
t3_bak=$(declare -f t3); echo "mcp:fresh" > "$R/fresh"; t3() { echo "Thread $3 was not found." >&2; return 1; }
fixer_at_work "$R/fresh"
t3() { echo "Thread $3 is no longer available."; }
if fixer_at_work "$R/fresh"; then echo "unexpected: a gone fixer still at work" >&2; exit 1; fi
eval "$t3_bak"
echo 'fixer-at-work checks passed'

# every liveness check treats a fixer still preparing its workspace as at work (review of 3de96e91b)
eval "$(sed -n '/^fixer_live() {/,/^}/p; /^fixer_thread_state() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in fixer_live fixer_thread_state; do declare -F "$_f" >/dev/null || { echo "missing helper $_f" >&2; exit 1; }; done
echo "mcp:prep" > "$STATE/sent/abc.fixer-blocked"
t3_status=preparing
fixer_live abc blocked                                      # preparing → still the owner of its receipt
echo 'preparing liveness checks passed'

# dev_fixer_free: the slot follows every fixer of the active sha — fixer-blocked AND the per-group authorto-<hash> ones
# (re-check of 46686e7a3 #8: an ended authorto fixer kept the slot until the 60 min timeout)
eval "$(sed -n '/^dev_fixer_free() {/,/^}/p; /^fixer_thread_state() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in dev_fixer_free fixer_thread_state; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
log() { echo "$*" >> "$STATE/log"; }
AS=$(printf 'a%.0s' $(seq 1 40)); NS=$(printf 'b%.0s' $(seq 1 40))
rm -f "$STATE"/sent/*; echo "$AS" > "$STATE/dev-fixer.active"
echo "mcp:grp" > "$STATE/sent/$AS.fixer-authorto-123456789"
t3_status=running;   ! dev_fixer_free "$NS" || { echo "negative check failed: test/ci/review-dispatch-culprits.sh:113" >&2; exit 1; }        # its group fixer is at work → slot held
t3_status=preparing; ! dev_fixer_free "$NS" || { echo "negative check failed: test/ci/review-dispatch-culprits.sh:114" >&2; exit 1; }        # preparing = at work too
t3_status=interrupted; dev_fixer_free "$NS"        # ended → free now, not after 60 min
grep -q 'slot freed' "$STATE/log"
echo "mcp:blk" > "$STATE/sent/$AS.fixer-blocked"   # two fixers: free only when both ended
t3() { case "$3" in mcp:blk) echo "$3 running" ;; *) echo "$3 completed" ;; esac; }
! dev_fixer_free "$NS" || { echo "negative check failed: test/ci/review-dispatch-culprits.sh:119" >&2; exit 1; }
t3() { printf '%s %s\n' "$3" "$t3_status"; }; t3_status=completed; dev_fixer_free "$NS"
: > "$STATE/sent/$AS.fixer-authorto-123456789"; rm -f "$STATE/sent/$AS.fixer-blocked"   # only an empty marker: not a fixer
rm -f "$STATE/log"; ! dev_fixer_free "$NS" || { echo "negative check failed: test/ci/review-dispatch-culprits.sh:122" >&2; exit 1; }; if [ -e "$STATE/log" ] && grep -q 'slot freed' "$STATE/log"; then echo "negative check failed: test/ci/review-dispatch-culprits.sh:122" >&2; exit 1; fi
# re-check of 0b463b6c0 #9: a fixer T3 no longer has ("no longer available") frees the slot, read the shared way
rm -f "$STATE"/sent/* "$STATE/log"; echo "$AS" > "$STATE/dev-fixer.active"; echo "mcp:gone" > "$STATE/sent/$AS.fixer-authorto-987654321"
t3() { echo "Thread $3 is no longer available."; }
dev_fixer_free "$NS"; grep -q 'slot freed' "$STATE/log"
t3() { printf '%s %s\n' "$3" "$t3_status"; }
# 11-12: a fixer that `t3 thread show` does not find YET (just launched) is not gone — it keeps the slot
rm -f "$STATE"/sent/* "$STATE/log"; echo "$AS" > "$STATE/dev-fixer.active"; echo "mcp:new" > "$STATE/sent/$AS.fixer-authorto-111111111"
t3() { echo "Thread $3 was not found." >&2; return 1; }
! dev_fixer_free "$NS" || { echo "negative check failed: test/ci/review-dispatch-culprits.sh:131" >&2; exit 1; }; ! grep -q 'slot freed' "$STATE/log" 2>/dev/null || { echo "negative check failed: test/ci/review-dispatch-culprits.sh:131" >&2; exit 1; }
# … while "no longer available" frees it, logged once however many runs see it
t3() { echo "Thread $3 is no longer available."; }
dev_fixer_free "$NS"; dev_fixer_free "$NS"; dev_fixer_free "$NS"
test "$(grep -c 'slot freed' "$STATE/log")" = 1
t3() { printf '%s %s\n' "$3" "$t3_status"; }
echo 'dev fixer slot: every fixer of the round counts'
# 11-12 22:37Z: a commit the dispatcher made (Loop: review-dispatch) has no author thread
TD=$(mktemp -d); git -C "$TD" init -q; git -C "$TD" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "revert on dev" -m "Loop: review-dispatch
Thread: 00000000-0000-4000-8000-0000000000c1"; RC=$(git -C "$TD" rev-parse HEAD)
git -C "$TD" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "feat" -m "Loop: adhoc/x
Thread: mcp:11111111-1111-1111-1111-111111111111"; FC=$(git -C "$TD" rev-parse HEAD)
SRC_BAK=$SRC; SRC=$TD
test -z "$(thread_of "$RC")"; test "$(thread_of "$FC")" = "mcp:11111111-1111-1111-1111-111111111111"
SRC=$SRC_BAK; rm -rf "$TD"
echo 'dispatcher commits: no author thread'
# 11-12 21:28Z: an unlisted transient state (a thread created seconds ago) is unknown, not over; a receipt < 3 min old is never over
eval "$(sed -n '/^fixer_ended() {/,/^}/p' scripts/ci/review-dispatch.sh)"; FIXER_GATE_STALE_MIN=90 FIXER_ENDED_GRACE_MIN=3
t3() { printf '%s %s\n' "$3" "idle"; }
test -z "$(fixer_thread_state mcp:x)"
echo "mcp:new" > "$STATE/sent/new.fixer-blocked"
t3() { printf '%s %s\n' "$3" "completed"; }
if fixer_ended "$STATE/sent/new.fixer-blocked" >/dev/null; then echo "unexpected: a fresh fixer judged over" >&2; exit 1; fi
touch -d '-10 min' "$STATE/sent/new.fixer-blocked"; fixer_ended "$STATE/sent/new.fixer-blocked" >/dev/null
t3() { printf '%s %s\n' "$3" "$t3_status"; }
echo 'fresh / transient fixers are not over'
