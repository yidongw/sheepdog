#!/usr/bin/env bash
# Exercise dispatcher routing under errexit with real notification failure paths.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
# Any command that is not found — a dispatcher helper the test did not extract — fails the whole test at once, even
# inside an if / || condition (review of 02828988f #7: "culprits_repaired: command not found" printed, test exited 0).
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
REVIEW_NOTIFY_HELPER=$PWD/scripts/ci/review-notify.sh
source scripts/ci/review-notify.sh
# Load the actual dispatcher adapters without running its production setup.
eval "$(sed -n '/^notify_best_effort() /p; /^notify_range() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in notify_best_effort notify_range; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
STATE=$(mktemp -d)
trap 'rm -rf "$STATE"' EXIT
mkdir -p "$STATE/sent"
log() { :; }
timeout() { return 1; }
curl() { printf '{"ok":false}\n'; }
key_prefix=''
range_threads() { printf '%s\n' invalid mcp:12345678-1234-1234-1234-123456789abc 12345678901234567; }
for thread in $(range_threads); do
  if [ "$thread" = invalid ]; then   # not a thread id: permanent → skipped once (receipt), never retried (11-12)
    notify abc direct "$thread" message; [ "$notify_outcome" = skipped ]; [ -e "$STATE/sent/abc.direct" ]; rm -f "$STATE/sent/abc.direct"
    continue
  fi
  if notify abc direct "$thread" message; then
    echo 'failed delivery unexpectedly succeeded' >&2; exit 1
  fi
  notify_best_effort abc direct "$thread" message
  fixer_woken=true
  test "$fixer_woken" = true
done
notify_range abc blocked message
fixer_woken=true
test "$fixer_woken" = true
# undeliverable recipients leave no receipt (retried next run) — except the non-thread id, skipped once for good
test "$(ls -A "$STATE/sent")" = "abc.blocked.0"
rm -f "$STATE"/sent/*
# A later successful delivery can still create its receipt.
timeout() { cat >/dev/null; }
notify_best_effort abc retry mcp:12345678-1234-1234-1234-123456789abc message
test -e "$STATE/sent/abc.retry"
echo 'notification dispatch regression checks passed'
# A failed fixer launch stays retryable; successful dispatch is deduplicated.
eval "$(sed -n '/^fixer_live() {/,/^}/p; /^FIXER_GATE_STALE_MIN=/,/^wake_fixer() {/{ /^wake_fixer() {/!p; }; /^wake_fixer() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in fixer_live wake_fixer; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
SRC=$PWD
DEV=dev
T3_PROJECT=test
# Prompt generation must work in isolated fixtures with SRC absent under nounset.
for provider in default claudeAgent codex; do
  (
    unset SRC FIXER_PROVIDER FIXER_MODEL
    case "$provider" in
      claudeAgent) FIXER_PROVIDER=claudeAgent ;;
      codex) FIXER_PROVIDER=codex; FIXER_MODEL=chosen ;;
    esac
    timeout() { cat >"$STATE/prompt-$provider"; }
    wake_fixer "prompt-$provider" hotfixfix title task main author-thread
    grep -q 'bash -c' "$STATE/prompt-$provider"
  )
done
SRC=$PWD
attempts="$STATE/attempts"
timeout() { cat >"$STATE/prompt"; echo attempt >>"$attempts"; return 1; }
for tick in 1 2; do
  timeout() { cat >/dev/null; }
  notify_best_effort deadbeef hotfix-notice mcp:12345678-1234-1234-1234-123456789abc message
  timeout() { cat >"$STATE/prompt"; echo attempt >>"$attempts"; return 1; }
  test ! -e "$STATE/sent/deadbeef.hotfix"
  if wake_fixer deadbeef hotfixfix title task main author-thread; then
    touch "$STATE/sent/deadbeef.hotfix"
  fi
done
test "$(wc -l <"$attempts")" -eq 2
test ! -e "$STATE/sent/deadbeef.hotfix"
test ! -e "$STATE/sent/deadbeef.fixer-hotfixfix"
# owner 11-12 (reviewer → fixer → author): the fixer reports to the dispatch log, never to the author threads
grep -q 'deadbeef fixer-report log'  "$STATE/prompt"
! grep -q 'author-thread' "$STATE/prompt" || { echo "negative check failed: test/ci/review-notify-dispatch.sh:78" >&2; exit 1; }
timeout() {
  if [ "${2:-}" = t3 ] && [ "${3:-}" = thread ] && [ "${4:-}" = show ]; then return 0; fi
  cat >/dev/null; echo attempt >>"$attempts";
}
wake_fixer deadbeef hotfixfix title task main author-thread
wake_fixer deadbeef hotfixfix title task main author-thread
test "$(wc -l <"$attempts")" -eq 3
test -e "$STATE/sent/deadbeef.fixer-hotfixfix"
echo 'fixer retry and reporting checks passed'

# (main re-check routing: test/ci/review-dispatch-main-owner.sh)
hotfix_notified=1
SRC=unused MAIN=main REPO=test/repo hsha=feedface hrun=123 hf=finding hbase=beefcafe
fix_budget_ok() { return 0; }   # the round budget has its own checks (review-dispatch-churn.sh); here: not spent
hotfix_fix_pushed() { return 1; }   # no fix commit yet
eval "$(sed -n '/^fixer_ended() {/,/^}/p; /^launch_failed() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in fixer_ended launch_failed; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
# the reviewer's route helpers (pure text parsing here: "finding" has no blocking finding → fixer)
for fn in finding_blocks finding_meta finding_route review_round_route route_reason attribution findings_subset att_of culprit_lines or_supervisor att_threads; do
  eval "$(sed -n "/^$fn() {/,/^}/p; /^$fn() { .*}\$/p" scripts/ci/review-dispatch.sh)"; for _f in "$fn"; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
done
notify() { echo "$2" >>"$STATE/hotfix-notices"; }
eval "$(sed -n '/^obsolete_rule() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in obsolete_rule; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
thread_of() { echo author-thread; }
wake_fixer() {
  test "$#" -eq 6 || exit 1
  test "$6" = author-thread || exit 1
  echo "$2" >>"$STATE/routes"
  return 1
}
# Exercise the actual blocked-dev caller (dev_blocked) and require the culprit authors as the fixer's record.
eval "$(sed -n '/^dev_blocked() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in dev_blocked; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
culprits_repaired() { return 1; }   # dev_blocked's "dev already repairs its culprits" check: not what this test is about
bsha=abc brid=123 bf=finding
# recipients are the culprits (commits touching a named file); "finding" names none → nobody (owner 11-12: no broadcast)
eval "$(sed -n '/^culprit_threads() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in culprit_threads; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
bcul=$(culprit_threads "$bsha" "$bf")
test -z "$bcul"
dev_fixer_free() { :; }   # the one-fixer-at-a-time gate has its own checks; here: free
dev_fixer_claim() { :; }
dev_carries_fix() { return 1; }
named_files() { :; }
blocked_author_reason() { :; }
fixer_phrase() { echo woken; }
wake_fixer() {
  test "$#" -eq 6 || exit 1
  test "$6" = "$bcul" || exit 1
  echo blocked >>"$STATE/routes"
}
dev_blocked "$bsha" "$bf" "$bcul" "run-url" "task"
test "$(tail -1 "$STATE/routes")" = blocked
echo 'production caller retry and recipient checks passed'

# Execute each sibling's actual call under errexit: failure must allow cleanup.
eval "$(sed -n '/^fixer_live() {/,/^}/p; /^FIXER_GATE_STALE_MIN=/,/^wake_fixer() {/{ /^wake_fixer() {/!p; }; /^wake_fixer() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in fixer_live wake_fixer; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
dsha=mainmerge-sha tsha=train-sha fh=fix-sha fs=base-sha msha=main-sha cfiles=""
fref=devfix/base frun=123
timeout() { cat >"$STATE/prompt"; return 1; }
for kind in mainmerge train testsfail landmain; do
  call=$(python3 - "$kind" <<'PY'
import sys
s = open('scripts/ci/review-dispatch.sh').read()
needle = {'mainmerge': 'wake_fixer "$dsha"', 'train': 'wake_fixer "$tsha"',
          'testsfail': 'wake_fixer "$fh" testsfail', 'landmain': 'wake_fixer "$fh" "landmain-'}[sys.argv[1]]
start = s.index(needle)
import re
m = re.search(r' \|\| (?:true|continue_mainmerge=1|continue)', s[start:])
end = start + m.end()
print(s[start:end])
PY
)
  ( eval "${call% ||*} || true"; touch "$STATE/continued-$kind" )
  test -e "$STATE/continued-$kind"
  test ! -e "$STATE/sent/$dsha.$msha.mainmerge"
  test ! -e "$STATE/sent/$fh.devfix-failed"
  test ! -e "$STATE/sent/$(case $kind in mainmerge) echo "$dsha.fixer-mainmerge-${msha:0:9}";; train) echo "$tsha.fixer-train-${msha:0:9}";; testsfail) echo "$fh.fixer-testsfail";; landmain) echo "$fh.fixer-landmain-${msha:0:9}";; esac)"
  grep -q 'fixer-report log' "$STATE/prompt"
  ! grep -q '12345678901234567' "$STATE/prompt"
done
echo 'sibling launch failure continuation and reporting checks passed'
# Check every sibling call's real arguments and failure guard under errexit.
python3 - <<'PY' >"$STATE/sibling-calls"
import re
s = open('scripts/ci/review-dispatch.sh').read()
for sha, key in [('dsha', 'mainmerge-'), ('tsha', 'train-'), ('fh', 'testsfail'), ('fh', 'landmain-')]:
    start = re.search(r'^ *wake_fixer "\$' + sha + r'" "?'+key, s, re.M).start()
    end = s.index('\n', s.index(' || ', start))
    call = s[start:end]
    if call.endswith('; }'):
        call = call[:-3]
    print(call)
PY
dsha=abc tsha=abc fh=abc fs=abc msha=abc fref=devfix/abc frun=123
wake_fixer() {
  test "$#" -eq 6 || exit 1   # arg 6 (culprit authors, log only) may be empty: no range-author fallback since owner 11-12
  echo sibling >>"$STATE/routes"
  return 1
}
# continue in the testsfail guard must remain local to the dispatch loop.
for tick in 1; do
  eval "$(cat "$STATE/sibling-calls")"
done
test "$(grep -c sibling "$STATE/routes")" -eq 4
# testsfail continued the loop; exercise the landing-conflict call separately.
for tick in 1; do
  eval "$(tail -1 "$STATE/sibling-calls")"
done
test "$(grep -c sibling "$STATE/routes")" -eq 5
echo 'sibling launch failure and recipient checks passed'
# The generated command is self-contained even outside a candidate checkout.
command=$(sed -n '/^  printf /p' "$STATE/prompt-default")
test -n "$command"
out=$( cd "$STATE"; DRY=1 eval "${command//<report>/a report}" )
grep -q '^DRY log fixer-report' <<<"$out"
# not DRY: the report lands in the STATE named in the command (the repo's own dispatch.log), no thread is sent anything
( cd "$STATE"; timeout() { echo "t3 must not be called" >&2; return 1; }; eval "${command//<report>/a report}" )
grep -q 'fixer-report prompt-de: a report' "$STATE/dispatch.log"
echo 'embedded notification command works without a repository helper'

# Notices require a successful launch receipt, including after a failed attempt.
eval "$(sed -n '/^fixer_phrase() {/,/^}/p; /^launch_phrase() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in fixer_phrase launch_phrase; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
dev_fixer_free() { return 0; }
test "$(fixer_phrase missing)" = "the fixer agent has not started yet; the dispatcher retries"
test "$(launch_phrase missing conflict)" = "the fixer agent has not started yet; the dispatcher retries"
touch "$STATE/sent/missing.fixer-blocked" "$STATE/sent/missing.fixer-conflict"
[[ "$(fixer_phrase missing)" == "woke a"* ]]
[[ "$(launch_phrase missing conflict)" == "woke a"* ]]
dev_fixer_free() { return 1; }
[[ "$(fixer_phrase deferred)" == "no new fixer agent"* ]]
echo 'fixer notices require launch receipts'

# a T3 thread that does not exist ("was not found") is skipped once, like an archived one (11-12: ~50 retries of a wrong Thread:)
rm -f "$STATE"/sent/*
timeout() { shift; "$@"; }
source scripts/ci/review-notify.sh   # the real notify (stubbed above)
t3() { echo "Thread $3 was not found." >&2; return 1; }
notify zz1 missing-thread mcp:12345678-1234-1234-1234-123456789abc message
[ "$notify_outcome" = skipped ]; [ -e "$STATE/sent/zz1.missing-thread" ]
echo 'missing thread: skipped once'
