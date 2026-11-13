#!/usr/bin/env bash
# Main findings (owner 11-13): every main commit is reviewed, repairs included; a blocked main re-check's findings go —
# purely by git trailers, no finding texts compared — to the OWNER (the Thread: of the root of the culprit commit's
# Review-Fix-Of: chain) when the culprit is no repair: normal send, 30 min without a repair → steer, risk → steer at once,
# owner unreachable → the strongest fixer; when the culprit IS a repair → the strongest fixer at once, effort by chain depth
# (1 → STRONG_FIXER_EFFORT, ≥ 2 → STRONG_FIXER_EFFORT_ESCALATED). No round budget on main. Fixer repairs name their
# findings (Fixes-Finding:) and ride the owner's next notice (digest). Steer goes through the T3 MCP tool, with a fallback.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
fns() { local n; for n in "$@"; do sed -n "/^$n() {/,/^}/p; /^$n() { .*}\$/p" "$D"; done; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DEV=dev REPO=test/repo FIXER_GATE=$T/state/fixer-gate SUPERVISOR_THREAD=import:claudeAgent:sup key_prefix=""
mkdir -p "$STATE/sent" "$FIXER_GATE/queue"
LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
source scripts/ci/review-notify.sh   # digest_add / digest_file / steer_thread / the real notify (kept as real_notify below)
eval "real_$(declare -f notify)"
eval "$(fns findings_cap thread_of fixer_receipt_thread norm_tid finding_blocks finding_meta finding_route attribute_finding attribution findings_subset \
  att_of named_files repair_effective fix_reverted fix_of launch_failed)"
helpers=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.find('# ── main re-checks, batched')
print(s[a:s.index('# ── hotfix commits on main', a)] if a >= 0 else '')
PY
)
eval "$helpers"
for f in main_blocked main_plan fix_depth digest_add steer_thread; do declare -F "$f" >/dev/null || fail "missing $f (the dispatcher has no main owner flow)"; done
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
blocked() { printf 'review-gate: FINDING #1 route=fixer commit=- — x\nreview-gate: BLOCKED #1 regression [%s]: %s\nevidence: %s:1 proof\n' "$1" "$2" "$3"; }
age() { local m=$1 st; st=$(head -1 "$m"); echo "${st%% *} $(( ${st#* } - $2 ))" > "$m"; }   # move a mark's clock back

# 1. a first fix is needed (culprit carries no Review-Fix-Of:) → the owner gets a normal send; no fixer
H=$(commit src/a.ts "Hotfix: a
Thread: $A"); push
F=$(blocked should "a drops rows" src/a.ts)
main_blocked "$H" "$F" "$BASE" 7
test "$(cat "$T/sent")" = "mainowner.${A//[^A-Za-z0-9-]/_} $A normal" || fail "owner not sent first: $(cat "$T/sent")"
test ! -e "$T/woken" || fail "a fixer woken for a first-time finding with a reachable owner"
grep -q 'a drops rows' "$T/msg-mainowner.${A//[^A-Za-z0-9-]/_}"; grep -q "Review-Fix-Of: $H" "$T/msg-mainowner.${A//[^A-Za-z0-9-]/_}"
grep -q 'Fixes-Finding:' "$T/msg-mainowner.${A//[^A-Za-z0-9-]/_}"
main_blocked "$H" "$F" "$BASE" 7
test "$(wc -l < "$T/sent")" = 1 || fail "owner re-sent within 30 min"
echo 'first time on main → owner, normal send'

# 2. 30 min without a repair → the owner is STEERED; another 30 min → the strongest fixer (no budget stop)
mark="$STATE/sent/$H.main-owner.${A//[^A-Za-z0-9-]/_}"
age "$mark" 1801
main_blocked "$H" "$F" "$BASE" 7
tail -1 "$T/sent" | grep -qx "mainsteer.${A//[^A-Za-z0-9-]/_} $A steer" || fail "no steer after 30 min: $(cat "$T/sent")"
test ! -e "$T/woken"
age "$mark" 1801
main_blocked "$H" "$F" "$BASE" 7
read -r _ key prov model eff < "$T/woken"
[[ "$key" == mainfix-* ]] && test "$prov $model $eff" = "claudeAgent claude-fable-5-2 medium" || fail "strongest fixer: $(cat "$T/woken")"
grep -q 'Fixes-Finding: #<n>' "$T/task-$key" || fail "fixer task does not demand Fixes-Finding:"
echo '30 min → steer; steered and silent → strongest fixer; no budget stop'

# 3. the owner's repair (Review-Fix-Of: H, their Thread:) on main completes H; no fixer
reset
main_blocked "$H" "$F" "$BASE" 7
R=$(commit src/a.ts "Hotfix: fix a
Review-Fix-Of: $H
Fixes-Finding: #1 a drops rows
Thread: $A"); push
main_blocked "$H" "$F" "$BASE" 7
test -e "$STATE/sent/$H.hotfix-complete" || fail "owner repair did not complete H"; test ! -e "$T/woken"
echo 'owner repair completes it'

# 4. a risk finding (security/permissions/funds/data-loss) → steered at once
reset
H2=$(commit src/b.ts "Hotfix: b
Thread: $B"); push
main_blocked "$H2" "$(blocked "blocker, funds" "b double-spends" src/b.ts)" "$R" 8
test "$(cat "$T/sent")" = "mainowner.${B//[^A-Za-z0-9-]/_} $B steer" || fail "risk not steered at once: $(cat "$T/sent")"
echo 'risk → steer at once'

# 5. owner unreachable (archived) → the strongest fixer at once; no Thread: at all (the dispatcher's own commit) → same
reset; UNREACHABLE=$B
main_blocked "$H2" "$(blocked should "b leaks" src/b.ts)" "$R" 8
grep -q "^$H2 mainfix-.* claudeAgent claude-fable-5-2 medium$" "$T/woken" || fail "unreachable owner: no strongest fixer"
UNREACHABLE=""; reset
H3=$(commit src/c.ts "Hotfix: c
Loop: review-dispatch
Thread: 00000000-0000-4000-8000-0000000000c1"); push
main_blocked "$H3" "$(blocked should "c breaks" src/c.ts)" "$H2" 9
test ! -e "$T/sent" || fail "the dispatcher's own commit has no owner to send to"
grep -q "^$H3 mainfix-" "$T/woken" || fail "no owner → no strongest fixer"
echo 'owner unreachable / none → strongest fixer at once'

# 6. the culprit IS a repair (the previous fix did not hold) → strongest fixer at once, depth 1 → normal effort,
#    depth ≥ 2 → escalated; owner = the chain root's author (A), who is not sent anything
reset
R1=$(commit src/c.ts "Hotfix: fix c
Review-Fix-Of: $H
Loop: dev-fixer
Thread: $FX"); push
main_blocked "$R1" "$(blocked should "still drops rows" src/c.ts)" "$H3" 10
test ! -e "$T/sent" || fail "a repair that did not hold went to the owner: $(cat "$T/sent")"
read -r _ key prov model eff < "$T/woken"; test "$eff" = medium || fail "depth 1 effort: $eff"
grep -q "depth 1; owner $A" "$T/task-$key" || fail "owner is not the chain root author: $(grep depth "$T/task-$key")"
reset
R2=$(commit src/c.ts "Hotfix: fix c again
Review-Fix-Of: $R1
Loop: dev-fixer
Thread: $FX"); push
STRONG_FIXER_EFFORT_ESCALATED=xhigh
main_blocked "$R2" "$(blocked should "still drops rows" src/c.ts)" "$R1" 11
read -r _ key prov model eff < "$T/woken"; test "$eff" = xhigh || fail "depth 2 effort: $eff"
grep -q "depth 2; owner $A" "$T/task-$key"
STRONG_FIXER_EFFORT_ESCALATED=high
echo 'repair that did not hold → strongest fixer, effort by chain depth; owner = chain root author'

# 7. the fixer's repair lands on main → complete; the owner's next notice (for anything) carries the digest, once
FR=$(commit src/c.ts "Hotfix: fix c for real
Review-Fix-Of: $R2
Fixes-Finding: #1 still drops rows
Loop: dev-fixer
Thread: $FX"); push
main_blocked "$R2" "$(blocked should "still drops rows" src/c.ts)" "$R1" 11
test -e "$STATE/sent/$R2.hotfix-complete" || fail "fixer repair did not complete"
grep -q "^${FR:0:9} main ${R2:0:9} #1 regression \[should\]: still drops rows" "$(digest_file "$A")" || fail "no digest line for the owner"
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\ncat > %q\necho Sent.\n' "$T/t3-got" > "$T/bin/t3"; chmod +x "$T/bin/t3"
PATH=$T/bin:$PATH real_notify zz1 anything "$A" "some other notice"
grep -q 'some other notice' "$T/t3-got"; grep -q "${FR:0:9} main ${R2:0:9} #1" "$T/t3-got" || fail "digest not appended to the next notice"
test ! -s "$(digest_file "$A")" || fail "digest not cleared after delivery"
echo 'fixer repair → digest on the owner'"'"'s next notice'

# 8. steer: through the T3 MCP tool; an idle thread gets a plain send; MCP unavailable → normal send, logged
printf '#!/usr/bin/env bash\necho "$1 $2" >> %q\ncase "$2" in *steer*) echo "t3-mcp: t3_thread_send failed: has no running turn that can be steered." >&2; exit 1 ;; esac\necho "{\\"delivery\\":\\"started\\"}"\n' "$T/mcp-calls" > "$T/mcp-idle"; chmod +x "$T/mcp-idle"
T3_MCP=$T/mcp-idle steer_thread "$A" "wake up"; test "$steer_how" = "idle, started"
grep -q '"mode":"steer"' "$T/mcp-calls"; grep -q '"mode":"auto"' "$T/mcp-calls"
printf '#!/usr/bin/env bash\necho "t3-mcp: initialize refused" >&2; exit 1\n' > "$T/mcp-down"; chmod +x "$T/mcp-down"
rm -f "$T/t3-got"; notify_mode=steer
T3_MCP=$T/mcp-down PATH=$T/bin:$PATH real_notify zz2 steerkey "$A" "steer me"; notify_mode=""
test "$notify_outcome" = sent; grep -q 'steer me' "$T/t3-got"; grep -q 'steer unavailable for steerkey' "$LOG" || fail "steer fallback not logged"
echo 'steer via MCP, idle → send, unavailable → queued send (logged)'

# 9. wake_fixer: the effort reaches t3_thread_launch; MCP down → t3 thread start without effort (logged)
eval "$(fns wake_fixer fixer_gate_pass fixer_prio)"
fixer_gate_pass() { return 0; }; T3_PROJECT=p REVIEW_NOTIFY_HELPER=scripts/ci/review-notify.sh
printf '#!/usr/bin/env bash\nif [ "$1" = t3_thread_launch ]; then printf "%%s\\n" "$2" > %q; else printf "%%s\\n" "$2" >> %q; fi\necho "{\\"threadId\\":\\"mcp:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\\",\\"delivery\\":\\"steered\\"}"\n' "$T/launch-args" "$T/steer-args" > "$T/mcp-launch"; chmod +x "$T/mcp-launch"
S40=$(printf 'e%.0s' $(seq 40))
T3_MCP=$T/mcp-launch wf_provider=claudeAgent wf_model=claude-fable-5-2 wf_effort=high wake_fixer "$S40" mainfix-abcdef012 title task main ""
jq -e '.modelSelection == {instanceId:"claudeAgent",model:"claude-fable-5-2",options:[{id:"effort",value:"high"}]} and .workspaceStrategy.baseRef == "origin/main"' "$T/launch-args" >/dev/null || fail "effort launch args: $(cat "$T/launch-args")"
test "$(cat "$STATE/sent/$S40.fixer-mainfix-abcdef012")" = mcp:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
jq -r .message "$T/launch-args" | grep -q 'Fixes-Finding: #<n>' || fail "fixer prompt does not ask to record the finding"
# (bake-off 11-13) proofs are worktree-local, never git stash; the fixer is told its own thread id right after launch
jq -r .message "$T/launch-args" | grep -q 'NEVER use git stash' || fail "fixer prompt still allows git stash"
if jq -r .message "$T/launch-args" | grep -q 'stash the fix'; then fail "fixer prompt still says stash the fix"; fi
jq -e 'select(.mode == "steer" and .threadId == "mcp:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" and (.message | contains("Thread: mcp:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")))' "$T/steer-args" >/dev/null || fail "the fixer was not told its own thread id"
grep -q 'reasoningEffort' <<<"$(T3_MCP=$T/mcp-launch wf_provider=codex wf_model=gpt-6.1-sol wf_effort=high wake_fixer "$S40" mainfix-abcdef014 title task main "" >/dev/null; cat "$T/launch-args")" || fail "codex launch does not use reasoningEffort"
printf '#!/usr/bin/env bash\ncase "$1 $2" in "thread start"*) echo "$*" > %q; echo mcp:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb ;; esac\n' "$T/start-args" > "$T/bin/t3"
T3_MCP=$T/mcp-down PATH=$T/bin:$PATH wf_provider=codex wf_model=gpt-6.1-sol wf_effort=xhigh wake_fixer "$S40" mainfix-abcdef013 title task main ""
grep -q -- '--provider codex --model gpt-6.1-sol' "$T/start-args"; grep -q 'launch with effort xhigh unavailable' "$LOG"
echo 'strongest fixer: effort via t3_thread_launch, CLI fallback'

# 9b. a repair only on dev keeps H pending (not complete) until it reaches main
reset
H5=$(commit src/e.ts "Hotfix: e
Thread: $A"); push
g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin
main_blocked "$H5" "$(blocked should "e is wrong" src/e.ts)" "$FR" 12
g checkout -q -B devw origin/dev; RD=$(commit src/e.ts "Review-Fix-Of: $H5
Thread: $A"); g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
main_blocked "$H5" "$(blocked should "e is wrong" src/e.ts)" "$FR" 12
test ! -e "$STATE/sent/$H5.hotfix-complete" || fail "a dev-only repair completed H"; grep -q "${RD:0:9} on dev only — pending" "$LOG"
g merge -q --ff-only devw; push
main_blocked "$H5" "$(blocked should "e is wrong" src/e.ts)" "$FR" 12
test -e "$STATE/sent/$H5.hotfix-complete" || fail "repair on main did not complete H"
echo 'dev-only repair pending; complete on main'

# 11. (re-check of dc5e2b504 #6) the chain root: abbreviated trailers resolve; no 20-link cut; an unverifiable link → owner
#     unknown (strongest fixer), never an intermediate repair's author
wake_fixer() { [ -e "$STATE/sent/$1.fixer-$2" ] && return 0   # the stub again (section 9 loaded the real one)
  echo "$1 $2 ${wf_provider:-} ${wf_model:-} ${wf_effort:-}" >> "$T/woken"; printf '%s\n' "$4" > "$T/task-$2"; echo "$FX" > "$STATE/sent/$1.fixer-$2"; }
eval "real_wake_$(declare -f wake_fixer)"
reset
C0=$(commit src/f.ts "Hotfix: f
Thread: $A"); push
C1=$(commit src/f.ts "Hotfix: f1
Review-Fix-Of: ${C0:0:9}
Thread: $B"); push
test "$(fix_depth "$C1")" = "1 $C0" || fail "abbreviated trailer: $(fix_depth "$C1")"
c=$C1; for i in $(seq 2 25); do c=$(commit src/f.ts "Hotfix: f$i
Review-Fix-Of: $c
Thread: $B"); done; push
test "$(fix_depth "$c")" = "25 $C0" || fail "long chain cut: $(fix_depth "$c")"
CX=$(commit src/f.ts "Hotfix: fx
Review-Fix-Of: $(printf 'b%.0s' $(seq 40))
Thread: $B"); push
test "$(fix_depth "$CX")" = "1 -" || fail "unverifiable link: $(fix_depth "$CX")"
main_blocked "$CX" "$(blocked should "f is wrong" src/f.ts)" "$c" 13
test ! -e "$T/sent" || fail "an unverifiable chain's intermediate author was told"
grep -q "^$CX mainfix-" "$T/woken" || fail "unknown owner → no strongest fixer"
echo 'chain root: abbreviated trailers, no cut, unverifiable → owner unknown'

# 12. (#3) numbered findings AND failed trusted tests: the test failures are an assignment of their own
reset
H6=$(commit src/g.ts "Hotfix: g
Thread: $A"); push
F6="$(blocked should "g is wrong" src/g.ts)
trusted tests job: failure
 FAIL test/g.test.ts > g adds
src/g.ts(1,1): error TS2304: Cannot find name 'zz'."
main_blocked "$H6" "$F6" "$CX" 14
grep -q '^0 ' "$STATE/sent/$H6.main-plan" || fail "no assignment for the failed tests: $(cat "$STATE/sent/$H6.main-plan")"
m="$T/msg-mainowner.${A//[^A-Za-z0-9-]/_}"
grep -q 'g is wrong' "$m"; grep -q 'FAIL test/g.test.ts' "$m"; grep -q 'TS2304' "$m" || fail "test failures dropped from the assignment"
echo 'numbered findings + failed tests: both assigned'

# 13. (#1/#2) the strongest fixer's launch refused twice → the supervisor is told (once, retryable); launches keep being retried
reset
wake_fixer() { echo "$1 $2" >> "$T/attempts"; echo x >> "$STATE/sent/$1.$2.launchfail"; return 1; }
for i in 1 2 3; do main_blocked "$R2" "$(blocked should "still drops rows" src/c.ts)" "$R1" 11; done
test "$(wc -l < "$T/attempts")" = 3 || fail "launch not retried every run"
test "$(grep -c "mainfix-launchfail.mainfix-.* $SUPERVISOR_THREAD" "$T/sent")" = 1 || fail "no (single) escalation of refused launches: $(cat "$T/sent" 2>/dev/null)"
grep -q 'still drops rows' "$T"/msg-mainfix-launchfail.*
eval "$(declare -f real_wake_wake_fixer | sed '1s/real_wake_wake_fixer/wake_fixer/')"
echo 'refused strongest-fixer launches: escalated, retried'

# 14. (#4) pre-existing findings: the CLI's exact line is recorded; a failed / empty log fetch is retried, not marked
reset; rm -f "$STATE/preexisting-findings.log"
GHLOG=ok
gh() { case "$*" in *runs/77/jobs*) echo '{"jobs":[{"name":"review","id":78}]}' ;;
  *jobs/78/logs*) [ "$GHLOG" = ok ] || return 1; echo '2026-11-13T03:40:00.1234567Z review-gate: NIT (non-blocking): regression: [pre-existing] One owner can close a batch (x.sh:1)'; echo '2026-11-13T03:40:00.1Z review-gate: NIT (non-blocking): ducktape: a plain nit' ;; esac; }
GHLOG=fail; preexisting_record "$H6" 77
test ! -e "$STATE/sent/$H6.preexisting-77" || fail "a failed log fetch marked the run processed"
GHLOG=ok; preexisting_record "$H6" 77
grep -q '^review-gate: NIT (non-blocking): regression: \[pre-existing\] One owner can close a batch' "$STATE/preexisting-findings.log" || fail "pre-existing line not recorded"
if grep -q 'a plain nit' "$STATE/preexisting-findings.log"; then fail "a plain nit recorded as pre-existing"; fi
test -e "$STATE/sent/$H6.preexisting-77"
echo 'pre-existing recorder: real format, marked only after a good fetch'

# 15. (#5) the digest: a notice carries 20 entries; the rest stay for the next notice
for i in $(seq 1 21); do digest_add "$B" "r$i fix $i"; done
PATH=$T/bin:$PATH real_notify zz3 other "$B" "notice one"
grep -q 'r20 fix 20' "$T/start-args" 2>/dev/null || true
test "$(cat "$(digest_file "$B")")" = "r21 fix 21" || fail "undelivered digest entries lost: $(cat "$(digest_file "$B")" 2>/dev/null)"
echo 'digest: delivered entries removed, the rest kept'

# 16. (bake-off 11-13) a fixer commit answers to the fixer thread the dispatcher launched, not to a Thread: it copied
reset
CI=00000000-0000-4000-8000-0000000000c1 F2=mcp:88888888-8888-8888-8888-888888888888
SB=$(commit src/k.ts "Hotfix: k
Thread: $A"); push
echo "$FX" > "$STATE/sent/$SB.fixer-mainfix-111111111"; touch -d '-10 min' "$STATE/sent/$SB.fixer-mainfix-111111111"
KC=$(commit src/k.ts "Hotfix: fix k
Review-Fix-Of: $SB
Loop: dev-fixer
Thread: $CI"); push
test "$(thread_of "$KC")" = "$FX" || fail "a fixer commit with a copied Thread: maps to $(thread_of "$KC"), not its fixer"
echo "$F2" > "$STATE/sent/$SB.fixer-mainfix-222222222"; touch -d '-5 min' "$STATE/sent/$SB.fixer-mainfix-222222222"
KD=$(commit src/k.ts "Hotfix: fix k again
Review-Fix-Of: ${SB:0:9}
Loop: dev-fixer
Thread: $CI"); push
test "$(thread_of "$KD")" = "$F2" || fail "the fixer launched last before the commit is not chosen: $(thread_of "$KD")"
KE=$(commit src/k.ts "Hotfix: fix k by the first fixer
Review-Fix-Of: $SB
Loop: dev-fixer
Thread: $FX"); push
test "$(thread_of "$KE")" = "$FX" || fail "a correct fixer Thread: was overridden"
KF=$(commit src/k.ts "Hotfix: owner fix
Review-Fix-Of: $SB
Thread: $A"); push
test "$(thread_of "$KF")" = "$A" || fail "a non-fixer commit was remapped"
test "$(repair_effective "$SB" "$FX" origin/main)" = "$KE"
echo 'fixer commits map to their launched fixer thread'
# re-check of aae189bed #1: one receipt→commit identity over the whole repair chain — initial, test-retry, conflict fixers
RA=mcp:aaaaaaaa-0000-0000-0000-00000000000a RB=mcp:bbbbbbbb-0000-0000-0000-00000000000b RC=mcp:cccccccc-0000-0000-0000-00000000000c
S9=$(commit src/q.ts "plain dev change
Thread: $A"); push
echo "$RA" > "$STATE/sent/$S9.fixer-blocked"; touch -d '-30 min' "$STATE/sent/$S9.fixer-blocked"
g checkout -q -B devfixw "$S9"
F9=$(commit src/q.ts "fix q
Review-Fix-Of: $S9
Loop: dev-fixer
Thread: $RA")
test "$(thread_of "$F9")" = "$RA" || fail "initial fixer: $(thread_of "$F9")"
# the trusted tests failed on F9 → a test-retry fixer B is launched under F9 (key testsfail), keeping Review-Fix-Of: S9
echo "$RB" > "$STATE/sent/$F9.fixer-testsfail"; touch -d '-20 min' "$STATE/sent/$F9.fixer-testsfail"
G9=$(commit src/q.ts "fix q, tests green
Review-Fix-Of: $S9
Loop: dev-fixer
Thread: $RB")
test "$(thread_of "$G9")" = "$RB" || fail "a test-retry commit with its own correct Thread: maps to $(thread_of "$G9")"
G9b=$(commit src/q.ts "fix q, retry copied the CI thread
Review-Fix-Of: $S9
Loop: dev-fixer
Thread: $CI")
test "$(thread_of "$G9b")" = "$RB" || fail "a copied Thread: in the retry flow maps to $(thread_of "$G9b"), not the retry fixer"
# main moved, landing conflicts → a conflict fixer C under F9 (key landmain-*): a merge of F9 into main, Review-Fix-Of: S9
echo "$RC" > "$STATE/sent/$F9.fixer-landmain-abcdef123"; touch -d '-10 min' "$STATE/sent/$F9.fixer-landmain-abcdef123"
g checkout -q main; commit src/other.ts "Hotfix: other
Thread: $A" >/dev/null
g merge -q --no-ff -m "merge fix" -m "Review-Fix-Of: $S9
Hotfix: review fix of ${S9:0:9} (conflict resolved)
Loop: dev-fixer
Thread: $RC" "$F9"; M9=$(g rev-parse HEAD); push
test "$(thread_of "$M9")" = "$RC" || fail "a conflict-resolution merge with its own correct Thread: maps to $(thread_of "$M9")"
echo 'the whole repair chain: initial, test-retry and conflict fixers keep their own thread'

# An intervening ancestor's newer receipt is eligible only when it repairs the same target.
# Check both a plain hotfix and a repair of another target; neither may win by time or by a copied Thread:.
for kind in hotfix unrelated-repair; do
  reset
  S10=$(commit src/target.ts "Hotfix: target for $kind
Thread: $A"); push
  echo "$RA" > "$STATE/sent/$S10.fixer-blocked"; touch -d '-30 min' "$STATE/sent/$S10.fixer-blocked"
  other_target=""
  [ "$kind" != unrelated-repair ] || other_target="Review-Fix-Of: $S9"
  U10=$(commit src/unrelated.ts "Hotfix: unrelated $kind
$other_target
Thread: $B")
  echo "$RB" > "$STATE/sent/$U10.fixer-blocked"; touch -d '-10 min' "$STATE/sent/$U10.fixer-blocked"
  C10=$(commit src/target.ts "Hotfix: repair target after $kind
Review-Fix-Of: $S10
Loop: dev-fixer
Thread: $CI"); push
  test "$(thread_of "$C10")" = "$RA" || fail "$kind ancestor's newer receipt stole the repair: $(thread_of "$C10")"
  test "$(repair_effective "$S10" "$RA" origin/main)" = "$C10" || fail "$kind ancestor hid the repair from its fixer's completion check"
  if repair_effective "$S10" "$RB" origin/main >/dev/null; then fail "$kind ancestor completed another fixer's work"; fi
  C10b=$(commit src/target.ts "Hotfix: repair target with unrelated fixer's copied Thread
Review-Fix-Of: $S10
Loop: dev-fixer
Thread: $RB")
  test "$(thread_of "$C10b")" = "$RA" || fail "$kind ancestor's unrelated fixer Thread was preserved"
done
echo 'unrelated ancestor receipts cannot own a repair or complete another fixer'

# A retry can repair multiple targets: receipts for an earlier trailer's repair still identify its fixer.
# Exercise both trailer orders, abbreviated targets, a valid Thread: and the copied-thread fallback.
for order in first-target-last second-target-last; do
  reset
  S11=$(commit src/multi-a.ts "Hotfix: multi-target a
Thread: $A")
  S12=$(commit src/multi-b.ts "Hotfix: multi-target b
Thread: $B")
  echo "$RA" > "$STATE/sent/$S12.fixer-blocked"; touch -d '-30 min' "$STATE/sent/$S12.fixer-blocked"
  F11=$(commit src/multi-a.ts "Hotfix: initial repair of a
Review-Fix-Of: $S11
Loop: dev-fixer
Thread: $RA")
  echo "$RB" > "$STATE/sent/$F11.fixer-testsfail"; touch -d '-20 min' "$STATE/sent/$F11.fixer-testsfail"
  targets="Review-Fix-Of: ${S11:0:9}
Review-Fix-Of: $S12"
  if [ "$order" = first-target-last ]; then
    targets="Review-Fix-Of: $S12
Review-Fix-Of: ${S11:0:9}"
  fi
  for trailer in "$RB" "$CI"; do
    C11=$(commit src/multi-a.ts "Hotfix: retry repairs both targets
$targets
Loop: dev-fixer
Thread: $trailer"); push
    test "$(thread_of "$C11")" = "$RB" || fail "$order multi-target retry ($trailer) maps to $(thread_of "$C11"), not its retry fixer"
    for target in "$S11" "$S12"; do
      test "$(repair_effective "$target" "$RB" origin/main)" = "$C11" || fail "$order multi-target retry hid the repair of $target"
      if repair_effective "$target" "$RA" origin/main | grep -qx "$C11"; then fail "$order multi-target retry completed another fixer's work"; fi
    done
  done
  # Initial fixer receipts must also be eligible for every target, regardless of trailer order.
  rm "$STATE/sent/$F11.fixer-testsfail" "$STATE/sent/$S12.fixer-blocked"
  echo "$RB" > "$STATE/sent/$S11.fixer-blocked"; touch -d '-20 min' "$STATE/sent/$S11.fixer-blocked"
  C11=$(commit src/multi-a.ts "Hotfix: initial fixer repairs both targets
$targets
Loop: dev-fixer
Thread: $CI")
  test "$(thread_of "$C11")" = "$RB" || fail "$order multi-target repair ignored an initial fixer receipt"
done
echo 'multi-target repairs keep their initial and retry fixer; every target completes'

# 10. the hotfix loop hands a blocked main re-check to main_blocked (no fix_budget_ok on main)
loop=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('# ── hotfix commits on main')
print(s[a:s.index('\ndone\n', a) + 6])
PY
)
grep -q 'main_blocked "$hsha"' <<<"$loop" || fail "the hotfix loop does not use main_blocked"
if grep -q 'fix_budget_ok' <<<"$loop"; then fail "the main loop still applies a round budget"; fi
echo 'main owner flow checks passed'
