#!/usr/bin/env bash
# A deployed verdict + legacy findings must still route while historical review evidence is unavailable.
# Exercise the real cache reader and owner walk; only external evidence, repair delivery and ownership are stubbed.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
for fn in dev_commit_verdict dev_owner_walk finding_jobs findings_tests dev_unknown_verdict; do
  eval "$(sed -n "/^$fn() {/,/^}/p; /^$fn() { .*}\$/p" "$D")"
  declare -F "$fn" >/dev/null || { echo "missing helper $fn" >&2; exit 1; }
done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
STATE=$T/state DEV_VERDICTS=$T/state/verdicts MAIN=main DEV=dev REPO=o/r DEV_ORPHAN_GRACE_SEC=0
S=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa RUN=42
mkdir -p "$DEV_VERDICTS" "$STATE/sent"
printf 'blocked %s 1 123 421\n' "$RUN" > "$DEV_VERDICTS/$S"
REVIEW=$(printf '%s\n' \
  "review-gate: FINDING #1 route=author commit=$S — preserve routing" \
  'review-gate: BLOCKED #1 regression [should]: drops rows' \
  'evidence: src/rows.ts:17 loses the row' \
  'review-gate: ROUTE author')
LEGACY="$REVIEW"$'\ntrusted tests job: failure\nFAIL stale-test\nerror TS stale-error\n##[error]stale-build'
printf '%s\n' "$LEGACY" > "$DEV_VERDICTS/$S.findings"
fail() { echo "FAIL: $*" >&2; exit 1; }
log() { :; }
review_first_verdict() { echo unavailable >> "$T/historical"; return 2; }
dev_unrepaired_load() { dev_commit_verdict "$S"; dev_unrepaired="$S ${dcv#* }"; }
dev_verdict_rotate() { :; }
dev_main_hold() { return 1; }
culprit_threads() { echo author-thread; }
dev_devfix_task() { echo repair-task; }
dev_blocked() { printf '%s\n' "$2" > "$T/routed"; echo called >> "$T/repairs"; }
dev_owner_state() { :; }   # nobody can own it: the same walk must reach orphan escalation
dev_escalate() { :; }      # the strongest-fixer escalation: test/ci/review-dispatch-devfix-rerun-escalate.sh
infra_alert() { printf '%s\n' "$5" > "$T/orphan"; }
ghc_note_jobs() { :; }
ghm() {
  case "$*" in
    "api repos/o/r/actions/runs/42/jobs")
      [ "$CURRENT" != unavailable ] || return 1
      printf '{"jobs":[{"name":"sheepdog / tests","id":425,"conclusion":"%s"}]}\n' "$CURRENT" ;;
    "api repos/o/r/actions/jobs/425/logs") echo '2026-11-17T00:00:00Z FAIL current-test' ;;
    *) fail "unexpected API call: $*" ;;
  esac
}

# Existing cached verdicts return without refetching; migration must still preserve routing AND orphan escalation.
CURRENT=success
dev_owner_walk
[ -f "$T/routed" ] || fail 'legacy blocked verdict lost repair routing when historical evidence was unavailable'
[ "$(cat "$T/routed")" = "$REVIEW" ] || fail 'legacy review metadata / evidence changed, or stale tests were routed'
[ -f "$T/orphan" ] && grep -qF "$REVIEW" "$T/orphan" || fail 'legacy blocked verdict lost orphan escalation'
[ "$(cat "$DEV_VERDICTS/$S.review-findings")" = "$REVIEW" ] || fail 'immutable review cache was not migrated'
[ "$(cat "$DEV_VERDICTS/$S.findings")" = "$LEGACY" ] || fail 'migration changed the legacy source'
[ ! -e "$T/historical" ] || fail 'migration tried to refetch historical evidence'
echo 'ok - legacy verdict preserves repair routing and orphan escalation without historical evidence'

# Later walks reuse the migration but refresh test failures, their logs, passing reruns and unavailable snapshots.
rm "$DEV_VERDICTS/$S.findings"
CURRENT=failure
dev_owner_walk
EXPECTED="$REVIEW"$'\ntrusted tests job: failure\nFAIL current-test'
[ "$(cat "$T/routed")" = "$EXPECTED" ] || fail 'current test failure was not refreshed independently'
CURRENT=success
dev_owner_walk
[ "$(cat "$T/routed")" = "$REVIEW" ] || fail 'passed rerun still routes an old test failure'
CURRENT=unavailable
dev_owner_walk
[ "$(cat "$T/routed")" = "$REVIEW" ] || fail 'unavailable current tests resurrected a cached failure'
[ "$(cat "$DEV_VERDICTS/$S.review-findings")" = "$REVIEW" ] || fail 'mutable test evidence entered the review cache'
echo 'ok - migrated review cache stays immutable while current test evidence changes'

# A dry run can use the same migration without writing it. A legacy cache without a tests suffix stays intact.
rm "$DEV_VERDICTS/$S.review-findings"
printf '%s\n' "$REVIEW" > "$DEV_VERDICTS/$S.findings"
DRY=1 CURRENT=success
dev_owner_walk
[ "$(cat "$T/routed")" = "$REVIEW" ] || fail 'review-only legacy cache was lost in dry run'
[ ! -e "$DEV_VERDICTS/$S.review-findings" ] || fail 'dry run persisted migrated findings'
unset DRY

# A cache with only tests supplies no review finding: retry historical evidence rather than inventing routing.
printf 'trusted tests job: failure\nFAIL stale-test\n' > "$DEV_VERDICTS/$S.findings"
rm "$T/routed" "$T/orphan"
dev_owner_walk
[ -e "$T/historical" ] || fail 'invalid legacy review evidence did not trigger a historical retry'
[ ! -e "$T/routed" ] && [ ! -e "$T/orphan" ] || fail 'test-only legacy cache was routed as a blocked review'
[ ! -e "$DEV_VERDICTS/$S.review-findings" ] || fail 'invalid legacy cache was persisted'
echo 'ok - dry run does not write migration; test-only legacy cache still retries review evidence'
