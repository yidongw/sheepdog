#!/usr/bin/env bash
# A main re-check whose review job failed BEFORE the code review ran (range / gates / setup step; the blocking step never
# ran) is an infrastructure failure, not a code finding (tralyx 11-14: "Review-Fix-Of must name an ancestor" in the
# Reviewed range step of every re-check became finding #0 → the strongest fixer → a dispute-only commit on main → the next
# failing re-check, all night). The dispatcher must:
#   · wake no owner, no fixer, no strongest fixer for it;
#   · tell the supervisor ONCE per episode (same failing step on the same main line, until a main review completes), with
#     the step name and a log excerpt — later heads of the episode are only logged, also on later dispatcher runs;
#   · settle those heads when a later completed main review covers them;
#   · never treat a dispute-only commit (Review-Fix-Of:, no file changed) as a repair: a finding pinned on it goes to the
#     commit it disputes, and it is no hop of a repair chain.
set -euo pipefail
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }   # gh-cache.sh (the per-run memo of review-dispatch.sh): here the fake gh itself
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
fns() { local n; for n in "$@"; do sed -n "/^$n() {/,/^}/p; /^$n() { .*}\$/p" "$D"; done; }
eval "$(fns findings findings_cap thread_of fixer_receipt_thread norm_tid finding_blocks finding_meta finding_route review_round_route route_reason \
  attribute_finding attribution findings_subset att_of culprit_lines named_files repair_effective fix_reverted hotfix_fix_pushed \
  author_turn author_fixed fyi_author or_supervisor fix_of)"
eval "$(fns review_list)"
digest_add() { :; }
helpers=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.find('# ── main re-checks, batched')
print(s[a:s.index('# ── hotfix commits on main', a)] if a >= 0 else '')
PY
)
loop=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('# ── hotfix commits on main')
print(s[a:s.index('\ndone\n', a) + 6])
PY
)
eval "$helpers"
for f in recheck_prereview_failed main_infra dispute_only; do declare -F "$f" >/dev/null || fail "missing $f"; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DEV=dev REPO=test/repo AUTHOR_FIX_WINDOW_SEC=3600 FIXER_GATE=$T/state/fixer-gate
SUPERVISOR_THREAD=import:claudeAgent:sup DISPATCH_THREAD=mcp:77777777-7777-7777-7777-777777777777 key_prefix=""
mkdir -p "$STATE/sent" "$FIXER_GATE/queue"
LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
A=mcp:11111111-1111-1111-1111-111111111111 FX=mcp:99999999-9999-9999-9999-999999999999
git init -q --bare "$T/remote.git"; git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
commit() { mkdir -p "$SRC/$(dirname "$1")"; printf '%s\n' "$RANDOM$RANDOM" >> "$SRC/$1"; g add "$1"; g commit -q -m "change $1" -m "$2"; g rev-parse HEAD; }
dispute() { g commit -q --allow-empty -m "review: dispute ${1:0:9}" -m "Hotfix: dispute
Review-Fix-Of: $1
Review-Disputed: #0 the review never ran
Loop: dev-fixer
Thread: $FX"; g rev-parse HEAD; }
push() { g push -q -f origin HEAD:refs/heads/main; g fetch -q origin; }
X=$(g commit -q --allow-empty -m base && g rev-parse HEAD)
H1=$(commit src/a.ts "Hotfix: a
Thread: $A")
H2=$(commit src/b.ts "Hotfix: b
Thread: $A"); push

# fake GitHub: runs.json (newest first); per run: jobs, conclusion, review-job log
runs='[]'
addrun() { # addrun <id> <sha> <kind: pass|range|gates|blocked|running>
  runs=$(jq -c --argjson id "$1" --arg t "recheck $2" --arg st "$([ "$3" = running ] && echo in_progress || echo completed)" \
    '[{event:"workflow_run",headBranch:"main",databaseId:$id,displayTitle:$t,status:$st}] + .' <<<"$runs")
  case "$3" in
    pass) echo '{"jobs":[{"name":"tests","id":'"$1"'0,"conclusion":"success"},{"name":"review","id":'"$1"'1,"conclusion":"success","steps":[{"name":"Reviewed range","conclusion":"success"},{"name":"Review (blocking; x)","conclusion":"success"}]}]}' > "$T/jobs-$1"
          echo success > "$T/concl-$1"; printf '2026-11-14T00:00:00Z review-range: %s %s\n' "$4" "$2" > "$T/log-$1" ;;
    range) echo '{"jobs":[{"name":"tests","id":'"$1"'0,"conclusion":"success"},{"name":"review","id":'"$1"'1,"conclusion":"failure","steps":[{"name":"Candidate","conclusion":"success"},{"name":"Reviewed range","conclusion":"failure"},{"name":"Commit gates (x)","conclusion":"skipped"},{"name":"Review (blocking; x)","conclusion":"skipped"}]}]}' > "$T/jobs-$1"
           echo failure > "$T/concl-$1"
           printf '2026-11-14T00:00:00Z ##[group]Run S=../.sheepdog/scripts/ci\n2026-11-14T00:00:00Z hotfix-review-base: the review of %s (run 9) has no usable coverage chain — not a base\n2026-11-14T00:00:01Z Review-Fix-Of must name an ancestor\n2026-11-14T00:00:01Z ##[error]Process completed with exit code 1.\n' "${X:0:12}" > "$T/log-$1" ;;
    gates) echo '{"jobs":[{"name":"tests","id":'"$1"'0,"conclusion":"failure"},{"name":"review","id":'"$1"'1,"conclusion":"failure","steps":[{"name":"Reviewed range","conclusion":"success"},{"name":"Commit gates (x)","conclusion":"failure"},{"name":"Review (blocking; x)","conclusion":"skipped"}]}]}' > "$T/jobs-$1"
           echo failure > "$T/concl-$1"; printf '2026-11-14T00:00:00Z [gates ERROR] commit abc missing Verify:\n2026-11-14T00:00:01Z ##[error]Process completed with exit code 3.\n' > "$T/log-$1" ;;
    blocked) echo '{"jobs":[{"name":"tests","id":'"$1"'0,"conclusion":"success"},{"name":"review","id":'"$1"'1,"conclusion":"failure","steps":[{"name":"Reviewed range","conclusion":"success"},{"name":"Review (blocking; x)","conclusion":"failure"}]}]}' > "$T/jobs-$1"
             echo failure > "$T/concl-$1"
             printf '2026-11-14T00:00:00Z review-range: %s %s\n2026-11-14T00:00:00Z review-gate: FINDING #1 route=fixer commit=- — x\n2026-11-14T00:00:00Z review-gate: BLOCKED #1 regression [should]: c drops rows\n2026-11-14T00:00:00Z evidence: src/c.ts:1 x\n' "$4" "$2" > "$T/log-$1" ;;
    running) echo '{"jobs":[]}' > "$T/jobs-$1"; echo null > "$T/concl-$1" ;;
  esac
  printf '%s\n' "$runs" > "$T/runs.json"; hotfix_runs=""; rc_heads=(); rc_heads_built=""; cov_base=()
}
gh() { local q="" a; for a in "$@"; do if [ "$q" = next ]; then q=$a; break; fi; if [ "$a" = -q ]; then q=next; fi; done
  if [ -n "$q" ] && [ "$q" != next ]; then gh_raw "$@" | jq -r "$q"; else gh_raw "$@"; fi; }
gh_raw() {
  local a="$*" id
  case "$a" in
    "run list"*) cat "$T/runs.json" ;;
    *actions/runs/*/jobs*) id=${a##*actions/runs/}; id=${id%%/*}; cat "$T/jobs-$id" ;;
    *actions/jobs/*/logs*) id=${a##*actions/jobs/}; id=${id%%/*}; cat "$T/log-${id%1}" 2>/dev/null ;;
    *actions/runs/*) id=${a##*actions/runs/}; id=${id%% *}; printf '{"conclusion":"%s"}\n' "$(cat "$T/concl-$id")" ;;
    *) echo '{}' ;;
  esac
}
wake_fixer() { [ -e "$STATE/sent/$1.fixer-$2" ] && return 0; echo "$1 $2" >> "$T/woken"; echo "$FX" > "$STATE/sent/$1.fixer-$2"; }
UNDELIVERED=""   # set: the next notice is not delivered (transport failure), nothing recorded, retryable
SKIP=" "   # threads that are gone (archived): notify records "skipped", as the real notify
notify() { if [ -e "$STATE/sent/$1.$2" ]; then notify_outcome=dup; [ "$(head -1 "$STATE/sent/$1.$2")" = skipped ] && notify_outcome=skipped; return 0; fi
  if [[ "$SKIP" == *" $3 "* ]]; then echo skipped > "$STATE/sent/$1.$2"; echo "$1 $2 $3" >> "$T/skipped"; notify_outcome=skipped; return 0; fi
  if [ -n "$UNDELIVERED" ]; then UNDELIVERED=""; echo "$1 $2" >> "$T/attempts"; notify_outcome=undelivered; return 1; fi
  echo "$1 $2 $3" >> "$T/sent"; printf '%s\n' "$4" > "$T/msg-$2"; notify_outcome=sent; touch "$STATE/sent/$1.$2"; }
notify_best_effort() { notify "$@" || :; }
fixer_ended() { return 1; }
sent_n() { if [ -e "$T/sent" ]; then wc -l < "$T/sent"; else echo 0; fi; }

# 1. H1 passed; H2's re-check failed in "Reviewed range" → nobody but the supervisor, once, with step + excerpt
addrun 1 "$H1" pass "$X"; addrun 2 "$H2" range
eval "$loop"
test ! -e "$T/woken" || fail "a fixer was woken for a pre-review failure: $(cat "$T/woken")"
test "$(sent_n)" = 1 || fail "expected exactly one notice: $(cat "$T/sent" 2>/dev/null) log: $(cat "$LOG" 2>/dev/null)"
read -r ns nk nt < "$T/sent"
[ "$ns $nt" = "$H2 $SUPERVISOR_THREAD" ] && [[ "$nk" == infra.* ]] || fail "the notice is not the supervisor's infra notice: $(cat "$T/sent")"
m=$T/msg-$nk
grep -q "review job step: Reviewed range" "$m" || fail "the notice does not name the failing step: $(cat "$m")"
grep -q 'Review-Fix-Of must name an ancestor' "$m" || fail "the notice has no log excerpt: $(cat "$m")"
if grep -q '##\[group\]' "$m"; then fail "the excerpt keeps log group markers"; fi
test ! -e "$STATE/sent/$H2.main-plan" || fail "a main plan (finding assignment) was made for a pre-review failure"
test ! -e "$STATE/sent/$H2.hotfix-complete" || fail "H2 was completed although nothing reviewed it"
test -e "$STATE/sent/$H1.hotfix-complete"
echo 'pre-review failure: supervisor told once (step + excerpt), no owner / fixer, no finding'

# 2. the next dispatcher run: nothing new
eval "$loop"
test "$(sent_n)" = 1 && test ! -e "$T/woken" || fail "repeated on the next run: $(cat "$T/sent")"
# 3. a later head of the same episode (a dispute-only commit) failing the same step: logged once, no notice, no fixer
H3=$(dispute "$H2"); push
addrun 3 "$H3" range
eval "$loop"; eval "$loop"
test "$(sent_n)" = 1 && test ! -e "$T/woken" || fail "a later head of the same episode was escalated again: $(cat "$T/sent" 2>/dev/null; cat "$T/woken" 2>/dev/null)"
test "$(grep -c "MAIN ${H3:0:9}: .*same episode as ${H2:0:9}" "$LOG")" = 1 || fail "the later head is not logged exactly once: $(grep "${H3:0:9}" "$LOG")"
echo 'same episode: later heads only logged, once; no repeat on later runs'
# 3b. a dispatcher that first meets several failed heads at once (newest first, e.g. after a pause) tells the supervisor once
mv "$STATE" "$T/state.keep"; mv "$T/sent" "$T/sent.keep"; mkdir -p "$STATE/sent" "$FIXER_GATE/queue"
cp "$T/state.keep/sent/$H1.hotfix-complete" "$STATE/sent/"
eval "$loop"
test "$(sent_n)" = 1 && test ! -e "$T/woken" || fail "several failed heads met at once: $(cat "$T/sent")"
rm -rf "$STATE" "$T/sent"; mv "$T/state.keep" "$STATE"; mv "$T/sent.keep" "$T/sent"
echo 'several failed heads met at once: one notice'

# 4. a different failing step on the same line is a new notice (commit gates; failed tests are part of it, not a finding)
H4=$(commit src/d.ts "Hotfix: d
Thread: $A"); push
addrun 4 "$H4" gates
eval "$loop"
test "$(sent_n)" = 2 && test ! -e "$T/woken" || fail "a new failing step: $(cat "$T/sent")"
grep -q 'review job step: Commit gates' "$T/msg-$(sed -n '2p' "$T/sent" | cut -d' ' -f2)" || fail "gates step not named"
echo 'another failing step: its own notice'

# 5. the machinery is fixed: the next re-check completes over the whole range → the open heads are settled, no fixer;
#    a later pre-review failure is a NEW episode (notified again)
H5=$(commit src/e.ts "Hotfix: e
Thread: $A"); push
addrun 5 "$H5" pass "$H1"
eval "$loop"
for h in "$H2" "$H3" "$H4" "$H5"; do test -e "$STATE/sent/$h.hotfix-complete" || fail "${h:0:9} not settled by the completed review that covers it"; done
test ! -e "$T/woken"
H6=$(commit src/f.ts "Hotfix: f
Thread: $A"); push
addrun 6 "$H6" range
eval "$loop"
test "$(sent_n)" = 3 && grep -q "^$H6 infra\\." "$T/sent" || fail "a new episode after a completed review was not notified: $(cat "$T/sent")"
echo 'completed review settles the episode; a later failure is a new episode'

# 6. a real verdict is still a finding (control): a blocked re-check goes to the owner as before
H7=$(commit src/c.ts "Hotfix: c
Thread: $A"); push
addrun 7 "$H7" blocked "$H6"
eval "$loop"
grep -q "^$H7 mainowner\\." "$T/sent" || fail "a real blocked verdict no longer reaches the owner: $(cat "$T/sent")"
echo 'control: a blocked verdict still goes to the owner'

# 7. dispute-only commits: no code, no hop. A finding pinned on one (here #0: tests failed on a dispute-only head) goes to
#    the commit it disputes — its owner, not the strongest fixer; fix_depth does not count it
DP=$(dispute "$H7"); push
test "$(fix_depth "$DP")" = "0 $H7" || fail "a dispute-only commit counted as a repair hop: $(fix_depth "$DP")"
dispute_only "$DP" || fail "dispute_only: an empty Review-Fix-Of: commit is not recognised"
if dispute_only "$H7"; then fail "dispute_only: a code commit"; fi
R1=$(commit src/c.ts "Hotfix: real repair
Review-Fix-Of: $H7
Thread: $A"); push
if dispute_only "$R1"; then fail "dispute_only: a real repair"; fi
test "$(fix_depth "$R1")" = "1 $H7" || fail "a real repair is a hop: $(fix_depth "$R1")"
plan=$(main_plan "$DP" "trusted tests job: failure" "$H7")
read -r pn pd pc proot powner _ <<<"$plan"
[ "$pn $pd $pc $proot $powner" = "0 0 $H7 $H7 $A" ] || fail "a finding on a dispute-only head is not pinned on the disputed commit's owner: $plan"
echo 'dispute-only commits: no repair hop; their findings go to the disputed commit'

# 8. (review of eff82b08e #2) an alert that was not delivered is retried on the next run — the episode is not "told" yet
rm -rf "$STATE" "$T/sent" "$T/attempts"; mkdir -p "$STATE/sent" "$FIXER_GATE/queue"
for h in $(git -C "$SRC" rev-list origin/main); do touch "$STATE/sent/$h.hotfix-complete"; done
H8=$(commit src/h.ts "Hotfix: h
Thread: $A"); push
addrun 8 "$H8" range
UNDELIVERED=1; eval "$loop"
test "$(wc -l < "$T/attempts")" = 1 && test "$(sent_n)" = 0 || fail "the undelivered alert: $(cat "$T/attempts" 2>/dev/null)"
H8b=$(dispute "$H8"); push; addrun 81 "$H8b" range
eval "$loop"
test "$(sent_n)" = 1 && grep -q "^$H8 infra\." "$T/sent" || fail "an undelivered alert was not retried: $(cat "$T/sent" 2>/dev/null)"
eval "$loop"; test "$(sent_n)" = 1 || fail "the delivered alert repeated"
echo 'undelivered alert: retried next run, then once'

# 9. (#3) the episode's own head re-run and REVIEWED ends the episode: the next failure is alerted again
addrun 8 "$H8" pass "$X"   # the rerun of H8's run (same id) passed
H9=$(commit src/i.ts "Hotfix: i
Thread: $A"); push; addrun 9 "$H9" range
eval "$loop"
test "$(sent_n)" = 2 && sed -n 2p "$T/sent" | grep -qE "^($H8b|$H9) infra\." || fail "a failure after the first head's successful rerun was not alerted: $(cat "$T/sent")"
echo 'a reviewed rerun of the first head ends the episode'

# 10. (NIT of eff82b08e, now a rule) repair_effective: a commit naming S that does not contain S repairs nothing
g checkout -q -b side "$X"; SD=$(commit src/s.ts "side work
Thread: $A")
g checkout -q main; NR=$(commit src/t.ts "Hotfix: claims to fix the side commit
Review-Fix-Of: $SD
Thread: $A"); push
if repair_effective "$SD" "" origin/main >/dev/null; then fail "repair_effective: a non-ancestor Review-Fix-Of: repaired S"; fi
g merge -q --no-ff -m "merge side" side; push
if repair_effective "$SD" "" origin/main >/dev/null; then fail "repair_effective: a non-ancestor repair counted once S is merged in"; fi
RS=$(commit src/s.ts "Hotfix: real fix
Review-Fix-Of: $SD
Thread: $A"); push
test "$(repair_effective "$SD" "" origin/main)" = "$RS" || fail "repair_effective: a real repair (S its ancestor) not found"
echo 'repair_effective: only a commit containing S repairs it'
fresh() { rm -rf "$STATE" "$T/sent" "$T/attempts" "$T/skipped"; mkdir -p "$STATE/sent" "$FIXER_GATE/queue"
  for h in $(git -C "$SRC" rev-list origin/main); do touch "$STATE/sent/$h.hotfix-complete"; done; }
# 13. (tralyx review of 71b7f7a77 #2) an archived supervisor thread: the alert goes to the CI owner; nobody reachable → no
#     receipt, logged once, retried after INFRA_UNREACHABLE_RETRY_SEC
g checkout -q main
fresh; SKIP=" $SUPERVISOR_THREAD "
H14=$(commit src/l.ts "Hotfix: l
Thread: $A"); push; addrun 14 "$H14" range
eval "$loop"
test "$(sent_n)" = 1 && grep -q "^$H14 infra\.[A-Za-z_]*\.owner $DISPATCH_THREAD$" "$T/sent" || fail "a gone supervisor: the CI owner did not get the alert: $(cat "$T/sent" 2>/dev/null)"
ls "$STATE"/infra-*.delivered."$H14".14 >/dev/null 2>&1 || fail "the delivered alert has no receipt"
fresh; SKIP=" $SUPERVISOR_THREAD $DISPATCH_THREAD "
H15=$(commit src/l2.ts "Hotfix: l2
Thread: $A"); push; addrun 15 "$H15" range
eval "$loop"; eval "$loop"
test "$(sent_n)" = 0 || fail "nobody reachable, yet sent: $(cat "$T/sent")"
if ls "$STATE"/infra-*.delivered.* >/dev/null 2>&1; then fail "an alert nobody received was recorded as delivered"; fi
test "$(grep -c "the infrastructure alert (run 15) reaches nobody" "$LOG")" = 1 || fail "unreachable not logged once: $(grep reaches "$LOG")"
SKIP=" "
touch -d '-2 hours' "$STATE/sent/$H15.infra-unreachable."*
eval "$loop"
test "$(sent_n)" = 1 && grep -q "^$H15 infra\." "$T/sent" || fail "the unreachable alert was not retried after the interval: $(cat "$T/sent" 2>/dev/null)"
echo 'gone supervisor → CI owner; nobody reachable → no receipt, retried later'

# 14. (#3) a receipt names its episode: the previous episode's receipt never acknowledges a new one, even when the
#     episode file was switched without its receipt being cleared (an interruption between the two writes)
fresh; SKIP=" "
H16=$(commit src/m.ts "Hotfix: m
Thread: $A"); push; addrun 16 "$H16" range
eval "$loop"; test "$(sent_n)" = 1 || fail "setup: first alert"
ef=$(ls "$STATE"/infra-* | grep -v '\.delivered' | head -1)
touch "$ef.delivered"   # a receipt of the old (unnamed) form, as an interruption would have left it
H17=$(dispute "$H16"); push; addrun 17 "$H17" range
touch "$STATE/sent/$H16.hotfix-complete"
echo "$H17 17" > "$ef"   # interrupted right after switching the episode file
eval "$loop"
test "$(sent_n)" = 2 && sed -n 2p "$T/sent" | grep -q "^$H17 infra\." || fail "the new episode was acknowledged by the old receipt: $(cat "$T/sent")"
echo 'receipts are bound to their episode head and run'
echo 'pre-review re-check failures checks passed'
