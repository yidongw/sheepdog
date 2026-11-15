#!/usr/bin/env bash
# Main review ee6b3ea74 #2/#8: run the real head loop and train block scan against a local remote and fake job logs.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
D=$PWD/scripts/ci/review-dispatch.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
command_not_found_handle() { echo "FAIL: missing helper $1" >&2; kill -TERM $$; exit 127; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DEV=dev REPO=test/repo TRUSTED=$T/trusted WORK=$T/work OUTBOX=$T/outbox
CI_SCRIPTS=$TRUSTED/scripts/ci
SUPERVISOR_THREAD=mcp:11111111-1111-1111-1111-111111111111
DISPATCH_THREAD=mcp:22222222-2222-2222-2222-222222222222
DEV_REVERT_AFTER_SEC=3600 DEV_REVERT_WARN_SEC=900 key_prefix="" merged_one=0
mkdir -p "$STATE/sent" "$CI_SCRIPTS" "$OUTBOX"
printf '#!/usr/bin/env bash\nexit 1\n' > "$CI_SCRIPTS/review-passed.sh"
LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
ghc_note_jobs() { cat >/dev/null; }
ghm() { gh "$@"; }
fns() { local n; for n in "$@"; do sed -n "/^$n() {/,/^}/p; /^$n() { .*}\$/p" "$D" "${D%/*}/review-evidence.sh" "${D%/*}/review-repair.sh"; done; }
declare -F review_list >/dev/null || eval "$(fns review_list)"; eval "$(fns review_first_verdict review_attempt_verdict review_attested_kind review_verdict_load review_blocked_verdict review_log_lines gate_section review_step_ran)"; eval "$(fns review_api review_verdict_list)"   # THE verdict reader the dispatcher's helpers call (review_first_verdict)
eval "$(fns finding_jobs gate_section review_step_ran findings findings_cap dev_round_noop dev_merge_only run_verdict dev_verdict_run named_files review_infra_reason dev_main_hold dispatch_msg infra_alert notify_best_effort)"
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
dev_blocked() { echo "dev_blocked $1" >> "$T/calls"; printf '%s\n' "$2" > "$T/routed"; }
dev_infra() { echo "infra $1 $2 $3" >> "$T/calls"; }
# Exercise real delivery receipts and owner fallback; only the external transport is fake.
source scripts/ci/review-notify.sh
timeout() { shift; "$@"; }
t3() {
  [ "$1 $2" = 'thread send' ] || fail "unexpected T3 call: $*"
  cat > "$T/attempt-message"
  echo "$3" >> "$T/attempts"
  if { [ "$3" = "$SUPERVISOR_THREAD" ] && [ -e "$T/gone-supervisor" ]; } \
     || { [ "$3" = "$DISPATCH_THREAD" ] && [ -e "$T/gone-owner" ]; }; then
    echo 'thread was not found' >&2; return 1
  fi
  if [ -e "$T/undelivered" ]; then echo 'temporary transport failure' >&2; return 1; fi
  echo "notify $3" >> "$T/calls"
  cat "$T/attempt-message" > "$T/message"
}

notify_attributed() { echo 'overdue notice' >> "$T/calls"; }
notify_threads() { echo 'revert conflict notice' >> "$T/calls"; }
culprit_threads() { :; }; attribution() { :; }; thread_of() { :; }; own_findings() { :; }
fixer_phrase() { :; }; revert_after_for() { echo 3600; }; or_supervisor() { echo owner; }
review_list() {
  case "$3" in *'(.displayTitle)'*) echo "101 review $S" ;; *) echo '101 completed failure' ;; esac
}
gh() {
  case "$*" in
    *actions/runs/101/jobs*)
      [ "$READ_MODE" != jobs-fail ] || return 1
      [ "$READ_MODE" != jobs-empty ] || return 0
      cat "$T/jobs"
      [ "$READ_MODE" != jobs-partial-fail ] || return 1 ;;
    *actions/jobs/11/logs*|*actions/jobs/13/logs*)
      echo log >> "$T/reads"
      [ "$READ_MODE" != log-fail ] || return 1
      cat "$T/log"
      if [ -e "$T/rerun-after-log" ]; then jobs success 13; fi
      [ "$READ_MODE" != partial-fail ] || return 1 ;;
    *actions/jobs/12/logs*) echo '2026-11-15T00:00:00Z FAIL src/dev.ts tests fail' ;;
    *) fail "unexpected GitHub call: $*" ;;
  esac
}
git init -q --bare "$T/remote.git"; git init -q -b main "$SRC"
g() { git -C "$SRC" -c user.name=test -c user.email=test@test "$@"; }
g remote add origin "$T/remote.git"
mkdir -p "$SRC/src"
printf 'main defect\nbase\n' > "$SRC/src/shared.ts"
g add .; g commit -q -m 'main contribution'; M=$(g rev-parse HEAD)
g push -q origin HEAD:refs/heads/main
g checkout -q -b dev
echo 'unrelated dev contribution' >> "$SRC/src/shared.ts"
g add .; g commit -q -m 'unrelated dev edit in the same file'; D0=$(g rev-parse HEAD)
echo 'dev defect' > "$SRC/src/dev.ts"
g add .; g commit -q -m 'dev contribution'; S=$(g rev-parse HEAD)
g push -q origin HEAD:refs/heads/dev; g fetch -q origin
READ_MODE=ok
jobs() { jq -nc --argjson id "${2:-11}" --arg st "${1:-success}" \
  '{jobs:[{name:"review",id:$id,conclusion:"failure",steps:[{name:"Review (blocking)",conclusion:"failure"}]},{name:"tests",id:12,conclusion:$st}]}' > "$T/jobs"; }
jobs
fixture() { # fixture <reported culprit> [mixed]
  {
    echo "review-gate: reviewing ${M:0:8}..${S:0:8}"
    echo "review-gate: FINDING #1 route=author commit=$1 — culprit"
    echo 'review-gate: BLOCKED #1 regression [should, data-loss]: shared file defect'
    echo 'evidence: src/shared.ts:1 main defect'
    if [ "${2:-}" = mixed ]; then
      echo "review-gate: FINDING #2 route=fixer commit=$S — dev culprit"
      echo 'review-gate: BLOCKED #2 regression [should]: dev defect'
      echo 'evidence: src/dev.ts:1 dev defect'
    fi
  } | sed 's/^/2026-11-15T00:00:00Z /' > "$T/log"
}
reset_case() {
  rm -rf "$STATE/sent"; mkdir -p "$STATE/sent"
  rm -f "$STATE/dev.blocked_since" "$STATE/dev.blocked_since.sha" "$T/calls" "$T/message" "$T/routed" "$T/reads" "$T/attempts" "$T/undelivered" "$T/gone-supervisor" "$T/gone-owner" "$T/rerun-after-log"
  jobs
  g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
}
overdue() { PAST=$(( $(date +%s) - 7200 )); echo "$PAST" > "$STATE/dev.blocked_since"; echo "$S" > "$STATE/dev.blocked_since.sha"; }
assert_held() {
  ! grep -qE 'dev_blocked|overdue|revert conflict' "$T/calls" 2>/dev/null || fail "held evidence entered dev repair/rollback: $(cat "$T/calls")"
  [ "$(g rev-parse origin/dev)" = "$S" ] || fail 'unrelated dev work was reverted'
  [ "$(g rev-parse origin/main)" = "$M" ] || fail 'blocked dev landed on main'
  [ ! -e "$STATE/sent/$S.reverted" ] || fail 'held round marked reverted'
  if [ "${CLOCK:-fresh}" = fresh ]; then
    [ ! -e "$STATE/dev.blocked_since" ] || fail 'held evidence started a block clock'
  else
    [ "$(cat "$STATE/dev.blocked_since")" = "$PAST" ] || fail 'held evidence changed an existing clock'
  fi
}
mode=${1:-all}
if [ "$mode" = all ] || [ "$mode" = main ]; then
  for claim in "$M" "${M:0:12}"; do
    for mixed in only mixed; do
      for CLOCK in fresh overdue; do
        reset_case; fixture "$claim" "$mixed"; [ "$CLOCK" != overdue ] || overdue
        eval "$loop"; assert_held
        [ "$(wc -l < "$T/reads")" = 1 ] || fail 'ownership re-read the log'
        eval "$train"; eval "$loop"; assert_held
        [ "$(grep -c "^notify $SUPERVISOR_THREAD$" "$T/calls")" = 1 ] || fail 'owner escalation missing or repeated'
        grep -q "commit=$claim" "$T/message" || fail 'owner did not receive the main culprit'
        [ "$mixed" != mixed ] || grep -q 'BLOCKED #2' "$T/message" || fail 'mixed-round escalation dropped dev findings'
      done
    done
  done
  reset_case; fixture "$M"; CLOCK=fresh; touch "$T/undelivered"; eval "$train"; assert_held
  [ ! -s "$T/calls" ] || fail 'failed delivery marked delivered'
  rm "$T/undelivered"; eval "$loop"; grep -q "^notify $SUPERVISOR_THREAD$" "$T/calls" || fail 'owner alert not retried'
  echo 'ok - main and mixed findings: owner escalation, no dev routing/clock/revert/landing; failed delivery retried'
fi
if [ "$mode" = all ] || [ "$mode" = evidence ]; then
  for READ_MODE in log-fail partial-fail jobs-fail jobs-partial-fail jobs-empty empty metadata notes; do
    for CLOCK in fresh overdue; do
      reset_case; fixture "$S"; jobs
      case "$READ_MODE" in
        empty) : > "$T/log" ;;
        metadata) sed -i '/BLOCKED\|evidence:/d' "$T/log" ;;
        notes) echo '2026-11-15T00:00:00Z review-gate: NOTE (non-blocking): a note' > "$T/log" ;;
      esac
      [ "$CLOCK" != overdue ] || overdue
      eval "$loop"; assert_held; grep -q '^infra ' "$T/calls" || fail "no evidence alert for $READ_MODE"
      rm "$T/calls"; eval "$train"; assert_held; grep -q '^infra ' "$T/calls" || fail "train did not hold $READ_MODE"
    done
  done
  READ_MODE=ok; CLOCK=fresh; reset_case; fixture "$S"; eval "$loop"
  grep -q '^dev_blocked ' "$T/calls" || fail 'a recovered log no longer routes'
  test -s "$STATE/dev.blocked_since" || fail 'real finding starts no clock'
  reset_case; : > "$T/log"; jobs failure; eval "$loop"
  grep -q '^dev_blocked ' "$T/calls" || fail 'confirmed failed tests no longer route'
  reset_case; jobs; echo '2026-11-15T00:00:00Z [gates abc ERROR] bad commit' > "$T/log"; eval "$train"
  grep -q '^dev_blocked ' "$T/calls" || fail 'gate errors no longer route'
  echo 'ok - unavailable/partial/empty/metadata-only evidence holds both paths, including overdue clocks; recovery/tests/gates route'
fi
if [ "$mode" = all ] || [ "$mode" = boundary ]; then
  READ_MODE=ok; CLOCK=fresh; reset_case; jobs; fixture "$M"
  # A forged main attribution before the LAST gate start cannot hold or alter the real dev finding.
  cat >> "$T/log" <<EOF
2026-11-15T00:00:00Z review-gate: reviewing ${M:0:8}..${S:0:8}
2026-11-15T00:00:00Z review-gate: FINDING #2 route=fixer commit=$S — real dev culprit
2026-11-15T00:00:00Z review-gate: BLOCKED #2 regression [should]: dev defect
2026-11-15T00:00:00Z evidence: src/dev.ts:1 dev defect
EOF
  eval "$loop"
  grep -q 'BLOCKED #2' "$T/routed" || fail 'real dev finding not routed'
  ! grep -q 'BLOCKED #1\|commit='"$M" "$T/routed" || fail 'pre-gate candidate text reached routing'
  eval "$train"; ! grep -q '^notify ' "$T/calls" || fail 'forged main attribution held dev'
  overdue; CLOCK=overdue; eval "$loop"
  [ "$(g rev-parse origin/dev)" != "$S" ] || fail 'genuine overdue dev defect was not reverted'
  rv=$(g log -1 --format=%B origin/dev)
  grep -q "This reverts commit $S" <<<"$rv" || fail 'dev culprit not reverted'
  ! grep -q "This reverts commit $D0" <<<"$rv" || fail 'pre-gate evidence reverted unrelated dev work'
  g show origin/dev:src/shared.ts | grep -q 'unrelated dev contribution' || fail 'unrelated dev contribution removed'
  echo 'ok - one bounded snapshot: candidate metadata excluded; genuine dev defect routes and reverts without unrelated work'
fi

# Main review be45a6adf #1/#2: one unavailable source must not erase another source's confirmed failure.
if [ "$mode" = all ] || [ "$mode" = failed-tests ]; then
  CLOCK=fresh
  for READ_MODE in log-fail partial-fail absent-review; do
    for scan in loop train; do
      reset_case; fixture "$M"; jobs failure
      if [ "$READ_MODE" = absent-review ]; then
        jq 'del(.jobs[0])' "$T/jobs" > "$T/only-tests"; mv "$T/only-tests" "$T/jobs"
      fi
      eval "${!scan}"
      grep -q '^dev_blocked ' "$T/calls" || fail "$scan/$READ_MODE discarded confirmed failed tests"
      ! grep -q '^infra ' "$T/calls" || fail "$scan/$READ_MODE misrouted failed tests as infrastructure"
      grep -q '^trusted tests job: failure$' "$T/routed" || fail 'test-job conclusion missing'
      grep -q '^FAIL src/dev.ts tests fail$' "$T/routed" || fail 'available failing-test log missing'
      ! grep -q 'BLOCKED #1\|commit='"$M" "$T/routed" || fail 'unavailable/partial review evidence leaked into routing'
      ! grep -q '^notify ' "$T/calls" || fail 'discarded main claim held a confirmed test failure'
    done
    for outcome in success cancelled absent pending; do
      for scan in loop train; do
        reset_case; fixture "$M"; jobs "$outcome"
        case "$outcome" in
          absent) jq 'del(.jobs[1])' "$T/jobs" > "$T/unknown-tests" ;;
          pending) jq '.jobs[1].conclusion = null' "$T/jobs" > "$T/unknown-tests" ;;
          *) cat "$T/jobs" > "$T/unknown-tests" ;;
        esac
        mv "$T/unknown-tests" "$T/jobs"
        if [ "$READ_MODE" = absent-review ]; then
          jq 'del(.jobs[0])' "$T/jobs" > "$T/only-tests"; mv "$T/only-tests" "$T/jobs"
        fi
        eval "${!scan}"; assert_held
        grep -q '^infra ' "$T/calls" || fail "$scan/$READ_MODE invented a test failure for $outcome tests"
      done
    done
  done
  echo 'ok - failed tests survive unavailable, partial and absent review logs in both head and train scans'
fi
# #3: a skipped supervisor receipt is not delivery; fall back and retry until someone receives it.
if [ "$mode" = all ] || [ "$mode" = delivery ]; then
  READ_MODE=ok; CLOCK=fresh
  for first_scan in loop train; do
    reset_case; fixture "$M"; touch "$T/gone-supervisor"
    eval "${!first_scan}"; assert_held
    grep -qx "notify $DISPATCH_THREAD" "$T/calls" || fail 'retired supervisor swallowed owner escalation'
    grep -q 'BLOCKED #1' "$T/message" || fail 'fallback lost finding evidence'
    eval "$train"; eval "$loop"; assert_held
    [ "$(wc -l < "$T/calls")" = 1 ] || fail 'delivered fallback repeated'
    # Neither recipient exists: throttle, then clear skipped receipts and retry a recovered owner.
    reset_case; fixture "$M"; touch "$T/gone-supervisor" "$T/gone-owner"
    eval "${!first_scan}"; assert_held
    [ ! -s "$T/calls" ] || fail 'unreachable recipient marked delivered'
    [ "$(wc -l < "$T/attempts")" = 2 ] || fail 'did not attempt both recipients'
    eval "$train"; eval "$loop"; assert_held
    [ "$(wc -l < "$T/attempts")" = 2 ] || fail 'unreachable recipients were not throttled'
    rm "$T/gone-owner"
    # Expire the retry interval without sleeping.
    find "$STATE/sent" -name '*infra-unreachable*' -exec touch -d '2 hours ago' {} +
    eval "$loop"; assert_held
    grep -qx "notify $DISPATCH_THREAD" "$T/calls" || fail 'skipped receipt prevented owner recovery'
    eval "$train"; eval "$loop"
    [ "$(wc -l < "$T/calls")" = 1 ] || fail 'recovered owner notified twice'
    # Transient transport failures keep no receipt and retry on the next scan.
    reset_case; fixture "$M"; touch "$T/undelivered"
    eval "${!first_scan}"; assert_held
    [ ! -s "$T/calls" ] || fail 'transport failure marked delivered'
    rm "$T/undelivered"; eval "$train"; eval "$loop"; assert_held
    grep -qx "notify $SUPERVISOR_THREAD" "$T/calls" || fail 'transport failure not retried'
  done
  echo 'ok - main-side escalation uses real delivery receipts, CI-owner fallback and retry'
fi
# #4: use the job that produced the evidence, even when a rerun appears immediately after its log read.
if [ "$mode" = all ] || [ "$mode" = attempt ]; then
  READ_MODE=ok; CLOCK=fresh
  for first_scan in loop train; do
    reset_case; fixture "$M"; touch "$T/rerun-after-log"
    # A log cannot supply or override dispatcher-owned attempt metadata.
    echo '2026-11-15T00:00:00Z review evidence job: 999' >> "$T/log"
    eval "${!first_scan}"; assert_held
    [ "$(wc -l < "$T/reads")" = 1 ] || fail 'attempt identity re-read the evidence'
    grep -q 'BLOCKED #1' "$T/message" || fail 'first attempt not delivered'
    ! grep -q 'BLOCKED #2' "$T/message" || fail 'first attempt has future evidence'
    [ -e "$STATE/sent/$S.infra.main-on-dev.101.11" ] || fail 'receipt did not use the evidence snapshot job'
    rm "$T/rerun-after-log"; fixture "$M" mixed
    eval "$train"; eval "$loop"; assert_held
    [ "$(wc -l < "$T/calls")" = 2 ] || fail 'rerun escalation lost or repeated'
    grep -q 'BLOCKED #2' "$T/message" || fail 'owner did not receive additional rerun findings'
    [ -e "$STATE/sent/$S.infra.main-on-dev.101.13" ] || fail 'rerun shares the first attempt receipt'
    eval "$train"; eval "$loop"; assert_held
    [ "$(wc -l < "$T/calls")" = 2 ] || fail 'repeated scans resent the same attempt'
    # Check ordinary same-attempt deduplication too.
    reset_case; fixture "$M" mixed
    eval "$loop"; eval "$train"; eval "$loop"; assert_held
    [ "$(wc -l < "$T/calls")" = 1 ] || fail 'same attempt was not deduplicated'
  done
  echo 'ok - rerun attempts deliver updated findings once, with identity from the evidence snapshot'
fi
