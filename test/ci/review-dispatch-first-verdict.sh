#!/usr/bin/env bash
# 746d20fe0 #3/#4/#5: exercise the dispatcher's real listing adapter, head loop, train scan and completion gate.
# Share the offline Git/GitHub fixture with the core reader regressions.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
ROOT=$PWD
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$ROOT/test/ci/lib/review-first-fixture.sh"
mode=${1:-all}
D=$ROOT/scripts/ci/review-dispatch.sh
# Add gh run list (bounded routing) alongside the fixture's paginated REST API (verdict evidence).
cat > "$T/bin/gh" <<GH
#!/usr/bin/env bash
q=""; a=("\$@"); for ((i=0;i<\${#a[@]};i++)); do [ "\${a[i]}" != -q ] || q=\${a[i+1]}; done
if [ "\$1 \$2" = 'run list' ]; then
  j=\$(head -100 "$T/api/list" | jq -sc 'map({databaseId:.id,displayTitle:.display_title,status,conclusion,event,headBranch:.head_branch,headSha:.head_sha})')
else
  [ "\$1" = api ] || exit 22
  case "\$2" in */zip|*/logs) exec "$T/bin/answer" "\$2" ;; esac
  j=\$("$T/bin/answer" "\$2") || exit 22
fi
if [ -n "\$q" ]; then jq -r "\$q" <<<"\$j"; else printf '%s\n' "\$j"; fi
GH
chmod +x "$T/bin/gh"
mkdir -p "$T/state/sent"
# Only repository and API reads are real production helpers. External routing actions are recorded locally.
cat > "$T/dispatch-fixture" <<'FIXTURE'
ROOT=$1 D=$1/scripts/ci/review-dispatch.sh T=$2
SRC=$PWD TRUSTED=$PWD STATE=$T/state CI_SCRIPTS=$ROOT/scripts/ci MAIN=main DEV=dev REPO=o/r
REVIEW_GIT_DIR=$SRC REVIEW_VERDICT_RANGES=0
DEV_REVERT_AFTER_SEC=3600 DEV_REVERT_WARN_SEC=900 key_prefix="" merged_one=1
source "$ROOT/scripts/ci/review-runs.sh"
source "$ROOT/scripts/ci/review-evidence.sh"
fns() { local n; for n in "$@"; do sed -n "/^$n() {/,/^}/p; /^$n() { .*}\$/p" "$D"; done; }
eval "$(fns review_api review_verdict_list review_list dev_verdict_run run_verdict finding_jobs findings findings_cap hotfix_pass_confirmed)"
ghm() { gh "$@"; }; ghc_note_jobs() { cat >/dev/null; }
log() { :; }
dev_merge_only() { return 1; }; dev_round_noop() { return 1; }; dev_main_hold() { return 1; }
culprit_threads() { :; }; revert_after_for() { echo 3600; }
dev_infra() { echo "INFRA $*"; }
review_infra_reason() { [ -z "$1" ]; }
dev_blocked() { printf '%s\n' "$1 $4" "$2"; }
FIXTURE
dispatch_eval() { env_ bash -eu -o pipefail -c 'source "$2/dispatch-fixture" "$1" "$2"; eval "$3"' _ "$ROOT" "$T" "$1"; }
# A single run blocked on attempt 1 and passed on attempt 2: both routing entry points must use attempt 1's findings.
# Remove attempt 1's jobs endpoint after selection to prove routing carries its already-read snapshot.
loop=$(python3 - "$D" <<'PY'
import sys
s=open(sys.argv[1]).read(); a=s.index('\nnow=$(date +%s)\nfor ref in ')+1
print(s[a:s.index('\ndone\n',a)+6])
PY
)
train=$(python3 - "$D" <<'PY'
import sys
s=open(sys.argv[1]).read(); a=s.index('  bl=$(review_list 100 databaseId,displayTitle,status,conclusion')
print(s[a:s.index('\n  for tsha in ',a)])
PY
)
g update-ref refs/remotes/origin/dev "$F"
# 9ee489fe9 #2: historical review evidence and latest tests must stay separate in every routing caller.
main_loop=$(python3 - "$D" <<'PYMAIN'
import sys
s=open(sys.argv[1]).read(); a=s.index('# ── hotfix commits on main')
print(s[a:s.index('\ndone\n',a)+6])
PYMAIN
)
if [[ "$mode" = all || "$mode" = tests-* ]]; then
H=$(c later "later dev work")
for route in head train main; do
  [[ "$mode" = all || "$mode" = tests-$route ]] || continue
  g update-ref refs/remotes/origin/dev "$F"
  [ "$route" != train ] || g update-ref refs/remotes/origin/dev "$H"
  for scenario in resolved current cancelled; do
    reset
    old=failure latest=success
    case "$scenario" in current) old=success latest=failure ;; cancelled) latest=cancelled ;; esac
    title=review; [ "$route" != main ] || title=recheck
    listing 30 "$title $F" 2 completed failure
    attempt 30 1 2 failure "$old"; attempt 30 2 2 success "$latest"
    att 30 "$F" "$N" review 1; att 30 "$F" "$N" review 2
    # Give historical and current test logs distinct identities, including called-workflow job names.
    for pair in '30.a1 3010' '30 3020'; do
      read -r file tid <<<"$pair"
      jq --argjson id "$tid" '.jobs |= map(if .name == "tests" then .id=$id else . end | .name = ("sheepdog / " + .name))' \
        "$T/api/$file.jobs" > "$T/jobs.tmp"
      mv "$T/jobs.tmp" "$T/api/$file.jobs"
    done
    echo '2026-11-15T00:00:00Z FAIL src/historical.test.ts' > "$T/api/3010.log"
    echo '2026-11-15T00:00:00Z FAIL src/current.test.ts' > "$T/api/3020.log"
    run1 32 "$title $F" failure "$N"
    # After verdict selection neither endpoint is available: callers must carry BOTH selected snapshots.
    code='eval "$(declare -f review_first_verdict | sed "1s/review_first_verdict/select_original/")"
      review_first_verdict() { select_original "$@"; rm -f "$T/api/30.a1.jobs" "$T/api/30.jobs"; }'
    case "$route" in
      head) body=$loop ;;
      train) body=$train ;;
      main)
        # Exercise the real hotfix loop and reader; stub only candidate discovery and external routing actions.
        code+=$'\nhotfix_candidates() { echo "'"$F"'"; }
          hotfix_expiring() { :; }; recheck_run() { echo 32; }
          recheck_reviewed() { return 0; }; recheck_base() { echo "'"$N"'"; }
          preexisting_record() { :; }; main_blocked() { printf "%s\\n" "$2"; }'
        body=$main_loop ;;
    esac
    out=$(dispatch_eval "$code"$'\n'"$body")
    [[ "$out" == *'finding of run 30 attempt 1'* ]] || fail "$route/$scenario lost historical review findings: $out"
    [[ "$out" != *'finding of run 32'* ]] || fail "$route/$scenario used a later review verdict"
    [[ "$out" != *'historical.test.ts'* ]] || fail "$route/$scenario resurrected historical test logs: $out"
    if [ "$scenario" = current ]; then
      [[ "$out" == *'trusted tests job: failure'* && "$out" == *'FAIL src/current.test.ts'* ]] \
        || fail "$route lost current test failure: $out"
    else
      [[ "$out" != *'trusted tests job:'* && "$out" != *'current.test.ts'* ]] \
        || fail "$route/$scenario routed superseded or cancelled test failures: $out"
    fi
  done
  echo "ok - $route preserves historical review findings and uses current test conclusions and logs"
done
g update-ref refs/remotes/origin/dev "$F"
fi
if [ "$mode" = all ] || [ "$mode" = routing ]; then
for extra in no yes; do
  reset
  listing 30 "review $F" 2 completed success; attempt 30 1 2 failure; attempt 30 2 2 success
  att 30 "$F" "$N" review 1; att 30 "$F" "$N" review 2
  [ "$extra" = no ] || run1 31 "review $F" success "$N"
  # Simulate the endpoint becoming unreadable after verdict selection; the reader's jobs snapshot remains usable.
  code='eval "$(declare -f dev_verdict_run | sed "1s/dev_verdict_run/select_original/")"
    dev_verdict_run() { select_original "$@"; rm -f "$T/api/30.a1.jobs"; }'
  out=$(dispatch_eval "$code"$'\n'"$loop")
  [[ "$out" == *'finding of run 30 attempt 1'* ]] || fail "head loop lost decisive findings ($extra extra run): $out"
  [[ "$out" != *INFRA* ]] || fail 'head loop routed the blocked attempt as infrastructure'
  attempt 30 1 2 failure
  # The scan discovers a later failing run but must route the immutable first verdict instead.
  run1 32 "review $F" failure "$N"
  out=$(dispatch_eval "$code"$'\n'"$train")
  [[ "$out" == *'finding of run 30 attempt 1'* ]] || fail "train scan lost decisive findings: $out"
  [[ "$out" != *'finding of run 32'* ]] || fail 'train scan routed later findings'
done
# A later failing scan candidate cannot route a head whose first verdict passed.
reset; run1 29 "review $F" success "$N"; run1 32 "review $F" failure "$N"
out=$(dispatch_eval "$train")
[ -z "$out" ] || fail "train scan routed a later block over the first passing verdict: $out"
echo 'ok - head and train routing retain the first attempt and its jobs snapshot (single and multiple runs)'
fi
if [ "$mode" = all ] || [ "$mode" = listing ]; then
# The oldest block is beyond the 100-run routing window. The actual adapter must agree with approval's reader.
reset; run1 103 "recheck $N" success "$P"
for i in $(seq 1 101); do listing "$((200+i))" "review $(printf '%040d' "$i")"; done
run1 1 "recheck $N" failure "$X"
out=$(dispatch_eval 'review_first_verdict_line "'"$N"'" recheck')
[ "$out" = 'blocked 1 1' ] || fail "dispatch forgot the first verdict beyond page 1: $out"
# A partial listing cannot decide absence (page 2 fails).
cp "$T/bin/answer" "$T/bin/answer-good"
sed -i '/case "\$u" in/a\  *workflows/review.yml/runs*page=2) exit 22 ;;' "$T/bin/answer"
out=$(dispatch_eval 'review_first_verdict_line "'"$N"'" recheck || [ "$?" = 2 ]')
[[ "$out" == unknown* ]] || fail "dispatch accepted incomplete verdict evidence: $out"
mv "$T/bin/answer-good" "$T/bin/answer"
echo 'ok - dispatcher verdicts use the complete trusted listing; unreadable pages stay unknown'
fi
if [ "$mode" = all ] || [ "$mode" = completion ]; then
# The completion gate uses the same whole-run success requirement as deployment.
reset; listing 40 "recheck $N" 1 completed failure; attempt 40 1 1 success; att 40 "$N" "$P" review 1
if dispatch_eval 'hotfix_pass_confirmed "'"$N"'"'; then fail 'failed workflow completed from its passing review step'; fi
reset; run1 40 "recheck $N" success "$P"
dispatch_eval 'hotfix_pass_confirmed "'"$N"'"' || fail 'control: successful main review cannot complete'
echo 'ok - main completion requires whole-run success'
fi
