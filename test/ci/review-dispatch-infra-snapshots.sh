#!/usr/bin/env bash
# Offline regressions for f879effb6: API failures cannot end an infrastructure episode, and retries must use its run's logs.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
# a helper the suite did not extract fails it (review of 96c16d11a #3: a missing findings / review_infra_reason made the negated
# completion check pass silently)
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
for fn in review_job_state recheck_infra_failed recheck_reviewed main_infra infra_alert infra_episode_open findings findings_cap review_infra_reason; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$D")"
  declare -F "$fn" >/dev/null || fail "missing $fn"
done
ghc_note_jobs() { cat > /dev/null; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state REPO=test/repo SUPERVISOR_THREAD=offline
mkdir -p "$STATE/sent"
git init -q -b main "$SRC"
g() { git -C "$SRC" -c user.name=test -c user.email=test@test "$@"; }
g commit -q --allow-empty -m first; H1=$(g rev-parse HEAD)
g commit -q --allow-empty -m second; H2=$(g rev-parse HEAD)
for id in 1 2; do
  jq -n --argjson jid "${id}1" '{jobs:[{name:"review",id:$jid,conclusion:"failure",steps:[
    {name:"Reviewed range",conclusion:"failure"},{name:"Review (blocking; x)",conclusion:"skipped"}]}]}' > "$T/jobs-$id"
done
J1=$(cat "$T/jobs-1"); J2=$(cat "$T/jobs-2")
FAIL_AFTER_FIRST= FAIL_ALL= UNDELIVERED=
review_jobs() {
  local n=0
  [ ! -e "$T/calls-$1" ] || n=$(cat "$T/calls-$1")
  echo "$((n + 1))" > "$T/calls-$1"
  if [ -n "$FAIL_ALL" ] || { [ -n "$FAIL_AFTER_FIRST" ] && [ "$n" -ge 1 ]; }; then return 1; fi
  cat "$T/jobs-$1"
}
recheck_run() { echo 1; }
recheck_covering() { return 1; }  # no later completed review covers this episode
log() { printf '%s\n' "$*" >> "$T/log"; }
REVIEW_LOG_11='##[error]run-1-only'
ghm() { case "$*" in
  *actions/jobs/11/logs) printf '2026-11-14T00:00:00Z %s\n' "$REVIEW_LOG_11" ;;
  *actions/jobs/21/logs) printf '2026-11-14T00:00:00Z ##[error]run-2-only\n' ;;
  *) fail "unexpected API request: $*" ;;
esac; }
notify() {
  if [ -n "$UNDELIVERED" ]; then UNDELIVERED=; notify_outcome=undelivered; return 1; fi
  printf '%s\n' "$1" >> "$T/sent"
  printf '%s\n' "$4" > "$T/message"
  notify_outcome=sent
}
mode=${1:-all}
if [ "$mode" = all ] || [ "$mode" = completion ]; then
  # The first jobs fetch shows a skipped review; every subsequent fetch fails. Keep the delivered episode open.
  FAIL_AFTER_FIRST=1
  main_infra "$H1" 1 "$J1" 'Reviewed range'
  main_infra "$H2" 2 "$J2" 'Reviewed range'
  [ "$(wc -l < "$T/sent")" = 1 ] || fail 'transient jobs failure closed the episode and sent a duplicate alert'
  [ "$(cat "$T/calls-1")" = 1 ] || fail 'completion fetched the jobs more than once'
  infra_episode_open "$H1" || fail 'unavailable jobs ended the episode'
  # An explicit failed lookup stays unknown even if a new fetch would return a successful review.
  FAIL_AFTER_FIRST=
  echo '{"jobs":[{"name":"review","conclusion":"success"}]}' > "$T/jobs-1"
  n=$(cat "$T/calls-1")
  if recheck_reviewed 1 ''; then fail 'an empty snapshot was treated as reviewed'; fi
  [ "$(cat "$T/calls-1")" = "$n" ] || fail 'an empty snapshot triggered another lookup'
  recheck_reviewed 1 || fail 'a verified successful rerun did not count as reviewed'
  if infra_episode_open "$H1"; then fail 'a verified successful rerun did not end the episode'; fi
  # Failed/timed-out jobs require the blocking step to have run; a skipped one still reviewed nothing.
  for outcome in failure timed_out; do
    j=$(jq --arg st "$outcome" '.jobs[0].conclusion=$st' <<<"$J1")
    if recheck_reviewed 1 "$j"; then fail "$outcome before review counted as reviewed"; fi
    j=$(jq '.jobs[0].steps[1].conclusion="failure"' <<<"$j")
    recheck_reviewed 1 "$j" || fail "$outcome after review was not recognised"
  done
  # the blocking step ran, but the reviewer itself did not (no finding): not reviewed — infrastructure, the step and the
  # reviewer's failure named; with failed trusted tests next to it, it is a reviewed (blocked) run
  j=$(jq '.jobs = [{name:"tests",id:10,conclusion:"success"}] + .jobs | .jobs[1].steps[1].conclusion="failure"' <<<"$J1")
  REVIEW_LOG_11='review-gate: reviewer failed: spawn E2BIG'
  if recheck_reviewed 1 "$j"; then fail 'a run whose reviewer failed to start counted as reviewed'; fi
  [ "$(recheck_infra_failed 1 "$j")" = 'Review (blocking; x) — reviewer failed: spawn E2BIG' ] || fail "recheck_infra_failed: $(recheck_infra_failed 1 "$j")"
  REVIEW_LOG_11=$'review-gate: BLOCKED #1 regression [should]: x\nevidence: a.ts:1'
  recheck_reviewed 1 "$j" || fail 'a run with a finding did not count as reviewed'
  REVIEW_LOG_11='##[error]run-1-only'
  FAIL_ALL=1
  if recheck_reviewed 1; then fail 'a failed jobs lookup counted as reviewed'; fi
  FAIL_ALL=
  echo 'completion: one snapshot; unknown keeps episode open; verified rerun ends it'
fi
if [ "$mode" = all ] || [ "$mode" = retry ]; then
  rm -rf "$STATE"; mkdir -p "$STATE/sent"
  rm -f "$T/sent" "$T/calls-1"
  printf '%s\n' "$J1" > "$T/jobs-1"
  UNDELIVERED=1
  main_infra "$H1" 1 "$J1" 'Reviewed range'
  main_infra "$H2" 2 "$J2" 'Reviewed range'
  [ "$(cat "$T/sent")" = "$H1" ] || fail 'retry changed the episode head'
  grep -q 'actions/runs/1$' "$T/message" || fail 'retry changed the episode run URL'
  grep -q 'run-1-only' "$T/message" || fail 'retry omitted the original run diagnostic'
  if grep -q 'run-2-only' "$T/message"; then fail 'retry attached another run diagnostic'; fi
  # If the original run is unavailable, report that rather than substitute the caller's diagnostic.
  rm -rf "$STATE"; mkdir -p "$STATE/sent"
  UNDELIVERED=1
  main_infra "$H1" 1 "$J1" 'Reviewed range'
  FAIL_ALL=1
  main_infra "$H2" 2 "$J2" 'Reviewed range'
  grep -q '(log unavailable)' "$T/message" || fail 'unavailable original jobs used another run diagnostic'
  if grep -q 'run-2-only' "$T/message"; then fail 'unavailable original jobs retained caller jobs'; fi
  echo 'retry: original run URL and diagnostic stay together, including unavailable jobs'
fi
