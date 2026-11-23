#!/usr/bin/env bash
# A main finding of H and a repair of its CULPRIT commit C on main (tralyx 11-23: the main re-check of the train merge
# ef25de16f blocked on #1, pinned on df1c3ce57; 77e61ef8e — Review-Fix-Of: df1c3ce57, "Fixes-Finding: #1 <df1c3ce57's own
# review text>" — was already on main; the dispatcher relaunched the strongest fixer and told the supervisor "Both strongest
# fixer agents ended without pushing a fix"). The culprit repair's numbers belong to C's own review: it covers a finding of
# H only when one of its lines carries that finding's text; with no such line it covers every finding pinned on C. A
# finding no line matches stays routed; the fixer records the existing repair with an empty commit Review-Fix-Of: H, which
# completes H by the numeric rule of repairs of H. Not counted: a culprit repair in H's own history, only on dev, or of a
# commit outside H's history.
set -euo pipefail
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }   # gh-cache.sh (the per-run memo of review-dispatch.sh): here the fake gh itself
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
fns() { local n; for n in "$@"; do sed -n "/^$n() {/,/^}/p; /^$n() { .*}\$/p" "$D" "${D%/*}/review-evidence.sh" "${D%/*}/review-repair.sh"; done; }
declare -F review_list >/dev/null || eval "$(fns review_list)"; eval "$(fns review_first_verdict review_attempt_verdict review_attested_kind review_verdict_load review_blocked_verdict review_log_lines gate_section review_step_ran)"; eval "$(fns review_api review_verdict_list)"   # THE verdict reader the dispatcher's helpers call (review_first_verdict)
source "${D%/*}/review-runs.sh"
hotfix_pass_confirmed() { :; }   # the completion gate (review-passed.sh REVIEW_PASSED_MODE=recheck): review-first-verdict.sh / the API budget run test it
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DEV=dev REPO=test/repo FIXER_GATE=$T/state/fixer-gate SUPERVISOR_THREAD=import:claudeAgent:sup key_prefix=""
mkdir -p "$STATE/sent" "$FIXER_GATE/queue"
LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
source scripts/ci/review-notify.sh   # digest_add / digest_file / steer_thread / the real notify (kept as real_notify below)
eval "real_$(declare -f notify)"
eval "$(fns findings_cap gate_section review_step_ran thread_of fixer_receipt_thread norm_tid finding_blocks finding_meta finding_route attribute_finding attribution findings_subset \
  att_of named_files repair_effective fix_reverted reverted fix_of launch_failed)"
helpers=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.find('# ── main re-checks, batched')
print(s[a:s.index('# ── hotfix commits on main', a)] if a >= 0 else '')
PY
)
eval "$helpers"
for f in main_blocked main_plan fix_depth digest_add steer_thread; do declare -F "$f" >/dev/null || fail "missing $f"; done
A=mcp:11111111-1111-1111-1111-111111111111 B=mcp:22222222-2222-2222-2222-222222222222 FX=mcp:99999999-9999-9999-9999-999999999999
git init -q --bare "$T/remote.git"; git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
commit() { # commit <file> <message body (trailers)> → sha
  mkdir -p "$SRC/$(dirname "$1")"; printf '%s\n' "$RANDOM$RANDOM" >> "$SRC/$1"; g add "$1"; g commit -q -m "change $1" -m "$2"; g rev-parse HEAD; }
push() { g push -q -f origin HEAD:refs/heads/main; g fetch -q origin; }
BASE=$(g commit -q --allow-empty -m base && g rev-parse HEAD); push
# stubs: notices, fixers, ended fixers
UNREACHABLE=""
notify() { local mode=${notify_mode:-normal}
  if [ -e "$STATE/sent/$1.$2" ]; then notify_outcome=dup; [ "$(head -1 "$STATE/sent/$1.$2")" = skipped ] && notify_outcome=skipped; return 0; fi   # receipts, as the real notify
  echo "$2 $3 $mode" >> "$T/sent"; printf '%s\n' "$4" > "$T/msg-$2"
  if [ -n "$UNREACHABLE" ] && [ "$3" = "$UNREACHABLE" ]; then notify_outcome=skipped; echo skipped > "$STATE/sent/$1.$2"; return 0; fi
  notify_outcome=sent; touch "$STATE/sent/$1.$2"; }
notify_best_effort() { notify "$@" || :; }
wake_fixer() { [ -e "$STATE/sent/$1.fixer-$2" ] && return 0
  echo "$1 $2 ${wf_provider:-} ${wf_model:-} ${wf_effort:-}" >> "$T/woken"; printf '%s\n' "$4" > "$T/task-$2"; echo "$FX" > "$STATE/sent/$1.fixer-$2"; }
FIXER_DONE=""; fixer_ended() { [ -n "$FIXER_DONE" ] && [ -e "$1" ] && { echo ended; return 0; }; return 1; }
fix_budget_ok() { return 1; }        # a spent dev budget means nothing on main (owner 11-13: no budget on main)
FIX_ROUNDS_MAX=0
reset() { rm -rf "$STATE/sent" "$T/sent" "$T/woken" "$T"/task-* "$T"/msg-*; mkdir -p "$STATE/sent"; }
age() { local m=$1 st; st=$(head -1 "$m"); echo "${st%% *} $(( ${st#* } - $2 ))" > "$m"; }   # move a mark's clock back
for f in culprit_reps culprit_open culprit_text_match finding_texts; do declare -F "$f" >/dev/null || fail "missing $f (the dispatcher ignores repairs of a finding's culprit commit)"; done
CI=mcp:cccccccc-cccc-cccc-cccc-cccccccccccc FX0=mcp:88888888-8888-8888-8888-888888888888 FX1=mcp:77777777-7777-7777-7777-777777777777
txt() { echo "Problem $1: the lock flag is cleared when mode and initialization come from different blocks ($1)"; }
fnd() { # fnd <file> <n>:<culprit>... → blocking findings, #n pinned on <culprit> by the reviewer's commit=, its text txt n
  local a n
  for a in "${@:2}"; do echo "review-gate: FINDING #${a%%:*} route=fixer commit=${a#*:} — x"; done
  for a in "${@:2}"; do n=${a%%:*}; printf 'review-gate: BLOCKED #%s regression [should, security]: %s\nevidence: %s:1 proof\n' "$n" "$(txt "$n")" "$1"; done; }
chain() { # chain <file> → sets ROOT (the owner's first commit) and C (a fixer's repair of ROOT: depth 1) on main
  ROOT=$(commit "$1" "Hotfix: $1
Thread: $A"); push
  C=$(commit "$1" "Hotfix: main review fix of ${ROOT:0:9}
Review-Fix-Of: $ROOT
Loop: dev-fixer
Thread: $FX0"); push; }
train() { H=$(commit "src/train-$1.ts" "Hotfix: train $1
Thread: $B"); push; }   # H: the reviewed head, its range carries C
nofail() { if grep -q mainfix-failed "$T/sent" 2>/dev/null; then fail "$1: the supervisor was told both fixers failed"; fi; }
empty() { g commit -q --allow-empty -m "record" -m "$1"; g rev-parse HEAD; }

# (a) tralyx ef25de16f: #1 pinned on C (a repair, depth 1 → the strongest fixer). The culprit's repair R names #1 with the
#     text of C's OWN review — not H's #1 → not covered (route keeps going). The fixer's task asks to record an existing
#     repair; its empty record commit (Review-Fix-Of: H, Fixes-Finding: #1 … (repaired by R)) completes H, no supervisor.
reset; HB=$(g rev-parse HEAD); chain src/a.ts; train a
F=$(fnd src/a.ts "1:$C")
main_blocked "$H" "$F" "$HB" 11
read -r _ key _ < "$T/woken" || fail "no strongest fixer for #1 on the repair C"
grep -q 'git commit --allow-empty' "$T/task-$key" || fail "the fixer task does not say how to record an existing repair"
grep -q '(repaired by <that commit'"'"'s sha>)' "$T/task-$key" || fail "the fixer task lacks the (repaired by <sha>) line"
grep -q "Review-Fix-Of: $H" "$T/task-$key"
R=$(commit src/a.ts "Hotfix: main review fix of ${C:0:9}
Review-Fix-Of: $C
Fixes-Finding: #1 Pin the runtime, mode, and initialization reads to one block and cover initialization between requests.
Loop: dev-fixer
Thread: $FX1"); push
main_blocked "$H" "$F" "$HB" 11
test ! -e "$STATE/sent/$H.hotfix-complete" || fail "a culprit repair naming #1 of its own review (another text) covered H's #1"
if grep -qs "covered by repair(s) ${R:0:9}" "$LOG"; then fail "logged coverage by ${R:0:9}"; fi
E=$(empty "Hotfix: main review fix of ${H:0:9} (record: already repaired on main)
Review-Fix-Of: $H
Fixes-Finding: #1 $(txt 1) (repaired by $R)
Loop: dev-fixer
Thread: $FX

Verify:
- [x] existing fix $R; test/x.test.ts covers it"); push
main_blocked "$H" "$F" "$HB" 11
test -e "$STATE/sent/$H.hotfix-complete" || fail "the record commit ${E:0:9} (Review-Fix-Of: H) did not complete H"
test "$(wc -l < "$T/woken")" = 1 || fail "a second fixer: $(cat "$T/woken")"
nofail "(a)"
echo 'culprit repair with another review'"'"'s #1 text: not covered; the fixer'"'"'s empty record commit completes H'

# (a2) the culprit's repair line carries H's finding text (case / spacing / a suffix differ) → covered: no fixer, complete
reset; HB=$(g rev-parse HEAD); chain src/a2.ts; train a2
F=$(fnd src/a2.ts "1:$C")
R=$(commit src/a2.ts "Hotfix: main review fix of ${C:0:9}
Review-Fix-Of: $C
Fixes-Finding: #3 $(txt 1 | tr '[:lower:]' '[:upper:]' | sed 's/ /   /g') (fixed in src/a2.ts)
Thread: $CI"); push
main_blocked "$H" "$F" "$HB" 12
test ! -e "$T/woken" || fail "a fixer for a finding whose text the culprit repair names: $(cat "$T/woken")"
test -e "$STATE/sent/$H.hotfix-complete" || fail "the culprit repair naming H's finding text did not complete H"
grep -q "MAIN ${H:0:9}: finding(s) covered by repair(s) ${R:0:9} (of ${C:0:9}) of their culprit commit(s) on main" "$LOG" || fail "no coverage log: $(cat "$LOG")"
echo 'culprit repair carrying the finding'"'"'s text (normalised) covers it, whatever its number'

# (b) same number, different finding: the culprit repair names "#1 <another finding>", H's #1 is not it → not covered
reset; HB=$(g rev-parse HEAD); chain src/b.ts; train b
F=$(fnd src/b.ts "1:$C")
commit src/b.ts "Hotfix: main review fix of ${C:0:9}
Review-Fix-Of: $C
Fixes-Finding: #1 Problem 7: an unrelated rounding error in the fee preview of the swap form
Thread: $CI" >/dev/null; push
main_blocked "$H" "$F" "$HB" 13
read -r _ key _ < "$T/woken" || fail "#1 is not routed although the culprit repair's #1 is a different finding"
grep -q 'Problem 1:' "$T/task-$key" || fail "fixer task lacks the open #1"
test ! -e "$STATE/sent/$H.hotfix-complete" || fail "same #1, different finding: H complete"
echo 'same #1, different finding → not covered'

# (b2) two findings on C, the culprit repair carries #2's text only → #1 stays with the strongest fixer (only #1 in its task)
reset; HB=$(g rev-parse HEAD); chain src/b2.ts; train b2
F=$(fnd src/b2.ts "1:$C" "2:$C")
commit src/b2.ts "Hotfix: fix of ${C:0:9}
Review-Fix-Of: $C
Fixes-Finding: #1 $(txt 2)
Thread: $CI" >/dev/null; push
main_blocked "$H" "$F" "$HB" 14
read -r _ key _ < "$T/woken" || fail "#1 is not routed"
grep -q 'Problem 1:' "$T/task-$key" || fail "fixer task lacks the open #1"
if grep -q 'Problem 2:' "$T/task-$key"; then fail "fixer task carries #2, whose text the culprit's repair names"; fi
test ! -e "$STATE/sent/$H.hotfix-complete" || fail "#1 open, H complete"
echo 'a culprit repair covers only the findings whose text it carries'

# (c) no Fixes-Finding: line → every finding pinned on that culprit; a finding pinned on another commit (D, owner B) stays
reset; HB=$(g rev-parse HEAD); chain src/c.ts
D=$(commit src/d.ts "Hotfix: d
Thread: $B"); push; train c
F=$(fnd src/c.ts "1:$C" "2:$C" "3:$D")
commit src/c.ts "Hotfix: fix ${C:0:9}
Review-Fix-Of: $C
Thread: $CI" >/dev/null; push
main_blocked "$H" "$F" "$HB" 15
test ! -e "$T/woken" || fail "a fixer was woken for #1 #2, which the culprit's repair covers: $(cat "$T/woken")"
test "$(cut -d' ' -f1,2 "$T/sent")" = "mainowner.${B//[^A-Za-z0-9-]/_} $B" || fail "#3 (on D) is not routed to its owner: $(cat "$T/sent")"
m="$T/msg-mainowner.${B//[^A-Za-z0-9-]/_}"
grep -q 'Problem 3:' "$m" || fail "owner notice lacks #3"
if grep -qE 'Problem [12]:' "$m"; then fail "owner notice carries the covered #1 #2"; fi
test ! -e "$STATE/sent/$H.hotfix-complete" || fail "#3 open, H complete"
echo 'a culprit repair without fix lines covers that culprit'"'"'s findings only'

# (d) the owner route (culprit depth 0): a culprit repair whose Review-Disputed: line carries the text covers it — the owner
#     is not notified
reset; HB=$(g rev-parse HEAD)
C0=$(commit src/e.ts "Hotfix: e
Thread: $A"); push; train d
F=$(fnd src/e.ts "1:$C0")
commit src/e.ts "Hotfix: fix ${C0:0:9}
Review-Fix-Of: $C0
Review-Disputed: #2 $(txt 1) — src/e.ts:1 already guarded
Thread: $CI" >/dev/null; push
main_blocked "$H" "$F" "$HB" 16
test ! -e "$T/sent" || fail "the owner was notified of a finding a repair of its culprit covers: $(cat "$T/sent")"
test -e "$STATE/sent/$H.hotfix-complete" || fail "Review-Disputed: with the finding's text on the culprit's repair did not complete H"
echo 'owner route: a culprit repair (Review-Disputed: <text>) covers it'
# (e) a repair of the culprit INSIDE H's reviewed history did not hold (H's review still found it) → not covered
reset; HB=$(g rev-parse HEAD); chain src/f.ts
commit src/f.ts "Hotfix: fix ${C:0:9}
Review-Fix-Of: $C
Thread: $CI" >/dev/null; push; train e
F=$(fnd src/f.ts "1:$C")
main_blocked "$H" "$F" "$HB" 17
test -e "$T/woken" || fail "a culprit repair H's own review saw counted as covering #1"
test ! -e "$STATE/sent/$H.hotfix-complete"
echo 'a culprit repair in H'"'"'s own history does not count'

# (f) a repair of the culprit only on dev does not count (main only)
reset; HB=$(g rev-parse HEAD); chain src/g.ts; train f
F=$(fnd src/g.ts "1:$C")
R=$(commit src/g.ts "Hotfix: fix ${C:0:9}
Review-Fix-Of: $C
Thread: $CI"); g push -q -f origin "$R:refs/heads/dev"; g reset -q --hard "$H"; g fetch -q origin
main_blocked "$H" "$F" "$HB" 16
test -e "$T/woken" || fail "a culprit repair only on dev counted as covering #1"
test ! -e "$STATE/sent/$H.hotfix-complete"
g push -q origin --delete dev; g fetch -q --prune origin
echo 'a culprit repair only on dev does not count'

# (g) a commit= that is no ancestor of H (a side branch) is ignored, its repair too
reset; HB=$(g rev-parse HEAD); train g0
g checkout -q -b side "$HB"; X=$(commit src/h.ts "Hotfix: side
Thread: $A")
commit src/h.ts "Hotfix: fix ${X:0:9}
Review-Fix-Of: $X
Thread: $CI" >/dev/null; g push -q origin side:refs/heads/side; g checkout -q main; g merge -q --no-edit side >/dev/null; push
H0=$H; F=$(fnd src/h.ts "1:$X")
main_blocked "$H0" "$F" "$HB" 17
test ! -e "$STATE/sent/$H0.hotfix-complete" || fail "a repair of a commit outside H's history completed H"
echo 'a culprit outside H'"'"'s history is ignored'
echo 'ok: main culprit repairs'
