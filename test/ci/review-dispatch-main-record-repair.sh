#!/usr/bin/env bash
# Only a repair of H covers H's main findings; a finding already repaired on main by another commit is RECORDED by the
# strongest fixer in a commit whose Review-Fix-Of names H (tralyx 11-23: the main re-check of the train merge ef25de16f
# blocked on #1, pinned on df1c3ce57; 77e61ef8e, a repair of df1c3ce57 carrying df1c3ce57's own review text, was already on
# main; both fixers reported "Existing fix: 77e61ef8e, no push needed" and the supervisor was told "Both strongest fixer
# agents ended without pushing a fix"). The fixer's task says how to record it: an empty commit, one
# "Fixes-Finding: #n <H's text> (repaired by <sha>)" line per finding; that commit completes H by the numeric rule.
# A repair of the culprit commit alone never covers H's findings (re-check of 67c436de8: that path was removed).
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

# (a) tralyx ef25de16f: #1 pinned on C (a repair, depth 1 → the strongest fixer), C's repair R already on main. R does not
#     cover H's #1; the fixer's task says how to record an existing repair; the empty record commit completes H — no
#     second fixer, no supervisor notice
reset; HB=$(g rev-parse HEAD); chain src/a.ts; train a
R=$(commit src/a.ts "Hotfix: main review fix of ${C:0:9}
Review-Fix-Of: $C
Fixes-Finding: #1 Pin the runtime, mode, and initialization reads to one block and cover initialization between requests.
Loop: dev-fixer
Thread: $FX1"); push
F=$(fnd src/a.ts "1:$C")
main_blocked "$H" "$F" "$HB" 11
read -r _ key _ < "$T/woken" || fail "no strongest fixer for #1 on the repair C"
grep -q 'git commit --allow-empty' "$T/task-$key" || fail "the fixer task does not say how to record an existing repair"
grep -qF '(repaired by <that commit'"'"'s sha>)' "$T/task-$key" || fail "the fixer task lacks the (repaired by <sha>) line"
grep -qF "Review-Fix-Of: $H" "$T/task-$key" || fail "the fixer task does not name H in the record's trailer"
grep -q 'name the existing fix' "$T/task-$key" || fail "the fixer task does not ask for the existing fix's evidence"
test ! -e "$STATE/sent/$H.hotfix-complete" || fail "a repair of the culprit ${C:0:9} covered H's #1"
E=$(empty "Hotfix: main review fix of ${H:0:9} (record: already repaired on main)
Review-Fix-Of: $H
Fixes-Finding: #1 $(txt 1) (repaired by $R)
Loop: dev-fixer
Thread: $FX

Verify:
- [x] existing fix $R; test/x.test.ts covers it"); push
main_blocked "$H" "$F" "$HB" 11
test -e "$STATE/sent/$H.hotfix-complete" || fail "the record commit ${E:0:9} did not complete H"
test "$(wc -l < "$T/woken")" = 1 || fail "a second fixer: $(cat "$T/woken")"
nofail "(a)"
echo 'an existing culprit repair is recorded by an empty commit naming H, which completes H'

# (b) a repair of the culprit naming no finding covers none of H's findings (re-check of 67c436de8 #1/#2)
reset; HB=$(g rev-parse HEAD); chain src/b.ts; train b
commit src/b.ts "Hotfix: fix ${C:0:9}
Review-Fix-Of: $C
Thread: $CI" >/dev/null; push
F=$(fnd src/b.ts "1:$C" "2:$C")
main_blocked "$H" "$F" "$HB" 12
read -r _ key _ < "$T/woken" || fail "#1 #2 are not routed although only the culprit was repaired"
grep -q 'Problem 1:' "$T/task-$key" && grep -q 'Problem 2:' "$T/task-$key" || fail "fixer task lacks #1 / #2"
test ! -e "$STATE/sent/$H.hotfix-complete" || fail "a repair of the culprit completed H"
echo 'a culprit repair alone covers none of H'"'"'s findings'
echo 'ok: main record repairs'
