#!/usr/bin/env bash
# A main repair covers the findings it names (owner 11-19; tralyx main 2e4b3b4d4: its repair e3a132c29 carried one
# Fixes-Finding: #4 line of five findings, and the dispatcher logged "every finding repaired" and stopped routing #1 #2 #3 #5).
# A repair of H with Fixes-Finding: #n / Review-Disputed: #n lines covers exactly those numbers, one with none covers all
# (as before); H is repaired once every BLOCKED #n is covered by the union of its repairs, and the uncovered ones keep
# going through the main route (owner → steer → strongest fixer) with only those findings. Routing only: review-repair.sh /
# review-passed.sh are unchanged.
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
blocked() { printf 'review-gate: reviewing a..b\nreview-gate: FINDING #1 route=fixer commit=- — x\nreview-gate: BLOCKED #1 regression [%s]: %s\nevidence: %s:1 proof\n' "$1" "$2" "$3"; }
age() { local m=$1 st; st=$(head -1 "$m"); echo "${st%% *} $(( ${st#* } - $2 ))" > "$m"; }   # move a mark's clock back

for f in repair_nums nums_open; do declare -F "$f" >/dev/null || fail "missing $f (the dispatcher does not compute per-finding coverage)"; done
CI=mcp:cccccccc-cccc-cccc-cccc-cccccccccccc
five() { # five <file> → five blocking findings, all on <file> (attributed to its author)
  echo 'review-gate: reviewing a..b'
  for n in 1 2 3 4 5; do echo "review-gate: FINDING #$n route=author commit=- — x"; done
  for n in 1 2 3 4 5; do printf 'review-gate: BLOCKED #%s regression [should]: problem%s-text\nevidence: %s:1 proof\n' "$n" "$n" "$1"; done; }
open_of() { tail -1 "$STATE/sent/$1.main-open" 2>/dev/null || true; }

# (a) tralyx 2e4b3b4d4 / e3a132c29: a repair naming #4 of five covers #4 only — #1 #2 #3 #5 stay routed (owner → steer →
#     strongest fixer, ONLY those findings in the notice / task), the log names them; H is not complete
H=$(commit src/a.ts "Hotfix: a
Thread: $A"); push
F=$(five src/a.ts)
main_blocked "$H" "$F" "$BASE" 7
mark="$STATE/sent/$H.main-owner.${A//[^A-Za-z0-9-]/_}"
test "$(head -1 "$mark" | cut -d' ' -f1)" = sent || fail "owner not sent: $(cat "$T/sent" 2>/dev/null)"
R4=$(commit src/a.ts "Hotfix: fix #4 of a
Review-Fix-Of: $H
Fixes-Finding: #4 problem4-text
Thread: $CI"); push
main_blocked "$H" "$F" "$BASE" 7
test ! -e "$STATE/sent/$H.hotfix-complete" || fail "a repair naming #4 of five completed H"
if grep -q "every finding repaired" "$LOG"; then fail "logged 'every finding repaired' after a partial repair"; fi
if grep -q "repaired by ${R4:0:9}" "$LOG"; then fail "logged 'repaired by' for a partial repair"; fi
grep -q "MAIN ${H:0:9}: repair(s) ${R4:0:9} on main cover only some findings — still open: #1 #2 #3 #5 " "$LOG" || fail "the log does not name the open findings: $(cat "$LOG")"
main_blocked "$H" "$F" "$BASE" 7
test "$(grep -c 'still open' "$LOG")" = 1 || fail "the open set is logged every run"
age "$mark" 1801
main_blocked "$H" "$F" "$BASE" 7
m="$T/msg-mainsteer.${A//[^A-Za-z0-9-]/_}"
test -e "$m" || fail "the owner was not steered for the open findings"
for n in 1 2 3 5; do grep -q "problem$n-text" "$m" || fail "steer lacks open finding #$n"; done
if grep -q 'problem4-text' "$m"; then fail "steer carries the repaired finding #4"; fi
age "$mark" 1801
main_blocked "$H" "$F" "$BASE" 7
read -r _ key _ < "$T/woken"
for n in 1 2 3 5; do grep -q "problem$n-text" "$T/task-$key" || fail "fixer task lacks open finding #$n"; done
if grep -q 'problem4-text' "$T/task-$key"; then fail "fixer task carries the repaired finding #4"; fi
test ! -e "$STATE/sent/$H.hotfix-complete"
echo 'partial Fixes-Finding: the rest stays routed (owner → steer → strongest fixer), logged, not complete'

# (a2) a culprit without an owner goes to the strongest fixer at once — with the open findings only
reset
H2=$(commit src/b.ts "Hotfix: b
Loop: review-dispatch
Thread: 00000000-0000-4000-8000-0000000000c1"); push
F2=$(five src/b.ts)
R2=$(commit src/b.ts "Hotfix: fix #2 of b
Review-Fix-Of: $H2
Fixes-Finding: #2 problem2-text
Thread: $CI"); push
main_blocked "$H2" "$F2" "$H" 8
read -r _ key _ < "$T/woken" || fail "no strongest fixer for the open findings"
for n in 1 3 4 5; do grep -q "problem$n-text" "$T/task-$key" || fail "fixer task lacks open finding #$n"; done
if grep -q 'problem2-text' "$T/task-$key"; then fail "fixer task carries the repaired finding #2"; fi
test ! -e "$STATE/sent/$H2.hotfix-complete"
echo 'no owner: the strongest fixer gets the open findings only'

# (b) the repairs together name every finding → repaired
R1235=$(commit src/a.ts "Hotfix: fix the rest of a
Review-Fix-Of: $H
Fixes-Finding: #1 problem1-text
Fixes-Finding: #2 problem2-text
Fixes-Finding: #3 problem3-text
Fixes-Finding: #5 problem5-text
Loop: dev-fixer
Thread: $FX"); push
main_blocked "$H" "$F" "$BASE" 7
test -e "$STATE/sent/$H.hotfix-complete" || fail "every finding named by the repairs, H not complete"
grep -q "HOTFIX ${H:0:9}: every finding repaired on main" "$LOG"
echo 'all numbers covered → repaired'

# (c) backward compatible: a repair with no Fixes-Finding: line covers every finding
H3=$(commit src/c.ts "Hotfix: c
Thread: $A"); push
F3=$(five src/c.ts)
main_blocked "$H3" "$F3" "$R1235" 9
commit src/c.ts "Hotfix: fix c
Review-Fix-Of: $H3
Thread: $CI" >/dev/null; push
main_blocked "$H3" "$F3" "$R1235" 9
test -e "$STATE/sent/$H3.hotfix-complete" || fail "a repair without Fixes-Finding: lines did not complete H"
echo 'no Fixes-Finding: lines → repaired (compat)'

# (d) Review-Disputed: #n counts as covered; without it that finding stays open
H4=$(commit src/d.ts "Hotfix: d
Thread: $A"); push
F4=$(five src/d.ts)
main_blocked "$H4" "$F4" "$H3" 10
D=$(commit src/d.ts "Hotfix: fix d
Review-Fix-Of: $H4
Fixes-Finding: #1 problem1-text
Fixes-Finding: #2 problem2-text
Review-Disputed: #3 src/d.ts:1 already clamps
Thread: $A"); push
main_blocked "$H4" "$F4" "$H3" 10
test ! -e "$STATE/sent/$H4.hotfix-complete" || fail "#4 #5 open, H complete"
test "$(open_of "$H4")" = "4 5 " || fail "open set: '$(open_of "$H4")'"
commit src/d.ts "Hotfix: dispute the rest
Review-Fix-Of: $H4
Review-Disputed: #4 src/d.ts:1 not reachable
Review-Disputed: 5 src/d.ts:1 not reachable
Thread: $A" >/dev/null; push
main_blocked "$H4" "$F4" "$H3" 10
test -e "$STATE/sent/$H4.hotfix-complete" || fail "Review-Disputed: #n did not count as covered"
echo 'Review-Disputed: #n counts as covered'
# (e) (re-check of 0c799ece7 #1/#2) an obsolete repair only on dev does not hold H pending once the repairs on main cover
#     every finding; a dev repair still needed for an open number does
for who in "$A" "$CI"; do
  H5=$(commit src/e.ts "Hotfix: e
Thread: $A"); push
  F5=$(five src/e.ts)
  main_blocked "$H5" "$F5" "$H4" 11
  g checkout -q -B devw main; commit src/e.ts "Review-Fix-Of: $H5
Thread: $A" >/dev/null; g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
  commit src/e.ts "Hotfix: fix e on main
Review-Fix-Of: $H5
Thread: $who" >/dev/null; push
  main_blocked "$H5" "$F5" "$H4" 11
  test -e "$STATE/sent/$H5.hotfix-complete" || fail "an obsolete dev repair holds H pending (main repair by $who covers all): $(tail -1 "$LOG")"
done
H6=$(commit src/f.ts "Hotfix: f
Thread: $A"); push
F6=$(five src/f.ts)
main_blocked "$H6" "$F6" "$H5" 12
g checkout -q -B devw main; RD=$(commit src/f.ts "Review-Fix-Of: $H6
Fixes-Finding: #5 problem5-text
Thread: $A"); g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
commit src/f.ts "Hotfix: fix f on main
Review-Fix-Of: $H6
Fixes-Finding: #1 problem1-text
Fixes-Finding: #2 problem2-text
Fixes-Finding: #3 problem3-text
Fixes-Finding: #4 problem4-text
Thread: $A" >/dev/null; push
main_blocked "$H6" "$F6" "$H5" 12
test ! -e "$STATE/sent/$H6.hotfix-complete" || fail "a dev repair still needed for #5 did not keep H pending"
grep -q "HOTFIX ${H6:0:9}: repair(s) ${RD:0:9} on dev only — pending" "$LOG" || fail "pending not logged for the needed dev repair"
echo 'obsolete dev repair: no pending once main covers everything; a needed one keeps H pending'

# (f) (re-check of 0c799ece7 #3) the owner digest credits each fixer repair only with the findings it names
reset
two() { printf 'review-gate: reviewing a..b\nreview-gate: FINDING #1 route=fixer commit=- — x\nreview-gate: FINDING #2 route=fixer commit=- — x\nreview-gate: BLOCKED #1 regression [should]: one-text\nevidence: src/g.ts:1 proof\nreview-gate: BLOCKED #2 regression [should]: two-text\nevidence: src/g.ts:1 proof\n'; }
G0=$(commit src/g.ts "Hotfix: g
Thread: $A"); push
G1=$(commit src/g.ts "Hotfix: fix g
Review-Fix-Of: $G0
Loop: dev-fixer
Thread: $FX"); push
GA=$(commit src/h.ts "Hotfix: fix #1 of g1
Review-Fix-Of: $G1
Fixes-Finding: #1 one-text
Loop: dev-fixer
Thread: $FX"); push
GB=$(commit src/h.ts "Hotfix: fix #2 of g1
Review-Fix-Of: $G1
Fixes-Finding: #2 two-text
Loop: dev-fixer
Thread: $FX"); push
rm -f "$(digest_file "$A")"
main_blocked "$G1" "$(two)" "$G0" 13
test -e "$STATE/sent/$G1.hotfix-complete" || fail "two fixer repairs naming #1 and #2: not complete"
dg=$(cat "$(digest_file "$A")")
grep -q "^${GA:0:9} main ${G1:0:9} #1 " <<<"$dg" && grep -q "^${GB:0:9} main ${G1:0:9} #2 " <<<"$dg" || fail "digest misses a repair: $dg"
if grep -qE "^${GA:0:9} main ${G1:0:9} #2 |^${GB:0:9} main ${G1:0:9} #1 " <<<"$dg"; then fail "digest credits a repair with a finding it does not name: $dg"; fi
test "$(wc -l <<<"$dg")" = 2 || fail "digest entries: $dg"
echo 'digest: each repair credited with the findings it names'
echo 'main partial-repair checks passed'
