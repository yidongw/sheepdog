#!/usr/bin/env bash
# 11-21 tralyx: the oldest unrepaired blocked dev commit waited 3 h+ for the one fixer slot, which a chain of main mainfix
# fixers held; each new dev head queued the same block again and each queued request was dropped as moot — nobody acted.
# dev_slot_wait: after DEV_SLOT_WAIT_MIN of waiting (slot held by another chain) the commit goes to its author(s) with the
# task to push one Review-Fix-Of: repair on dev — once per episode, again every further 2×DEV_SLOT_WAIT_MIN while
# unrepaired — and a moot drop never leaves it with neither a queued fixer nor a told owner (logged which). Slot ownership
# and priorities are unchanged: no fixer is woken by any of this.
set -euo pipefail
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }   # gh-cache.sh (the per-run memo of review-dispatch.sh): here the fake gh itself
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
fns() { local n b; for n in "$@"; do b=$(sed -n "/^$n() {/,/^}/p; /^$n() { .*}\$/p" "$D" "${D%/*}/review-repair.sh")
  if [ -z "$b" ]; then printf '{ echo "fns: helper %s not found in %s" >&2; exit 1; }\n' "$n" "$D"; else printf '%s\n' "$b"; fi; done; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DEV=dev REPO=test/repo SUPERVISOR_THREAD=import:claudeAgent:sup
DISPATCH_THREAD=00000000-0000-4000-8000-0000000000c1 key_prefix="" AUTHOR_FIX_WINDOW_SEC=3600 DEV_WALK_MAX=80
DEV_VERDICTS=$STATE/verdicts T3_PROJECT=test-project REVIEW_NOTIFY_HELPER=$PWD/scripts/ci/review-notify.sh
mkdir -p "$STATE/sent" "$DEV_VERDICTS"
LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
# the real gate (fixer_gate_pass / fixer_gate_scan) and the real slot-wait section
eval "$(sed -n '/^FIXER_GATE_STALE_MIN=/,/^wake_fixer() {/{ /^wake_fixer() {/d; p; }' "$D")"
eval "$(sed -n '/^DEV_SLOT_WAIT_MIN=/,/^dev_slot_wait() {/{ /^dev_slot_wait() {/d; p; }' "$D")"
eval "$(fns dev_slot_wait effective_repairs reverted thread_of fixer_receipt_thread norm_tid culprit_threads or_supervisor \
  notify_threads notify_best_effort notice_fallback notify_attributed attribution attribute_finding finding_blocks finding_meta \
  finding_route findings_subset named_files author_window_open budget_spent)"
for _f in fixer_gate_pass fixer_gate_scan dev_slot_wait dev_slot_hand dev_slot_own dev_slot_settled; do declare -F "$_f" >/dev/null || fail "missing helper $_f"; done
timeout() { shift; "$@"; }
# fake T3: thread states in files
T3D=$T/t3; mkdir -p "$T3D"
set_status() { echo "$2" > "$T3D/${1//:/_}"; }
t3() { case "$2" in show) if [ -e "$T3D/${3//:/_}" ]; then printf '%s  %s  codex\n' "$3" "$(cat "$T3D/${3//:/_}")"; else echo "Thread $3 is no longer available."; return 1; fi ;; esac; }
# fake notify: receipts like review-notify.sh's; a thread listed in $T/gone is archived (skipped)
notify() { local mark="$STATE/sent/$1.$2"
  if [ -e "$mark" ]; then notify_outcome=dup; [ "$(head -1 "$mark")" = skipped ] && notify_outcome=skipped; return 0; fi
  if grep -qxF "$3" "$T/gone" 2>/dev/null; then echo skipped > "$mark"; notify_outcome=skipped; return 0; fi
  printf '%s\t%s\t%s\n' "$2" "$3" "$(tr '\n' ' ' <<<"$4")" >> "$T/sent"; touch "$mark"; notify_outcome=sent; }
review_list() { jq -r "$3" "$T/runs.json" 2>/dev/null; }   # the trusted review runs (the cases below write them)
echo '[]' > "$T/runs.json"
sent() { cat "$T/sent" 2>/dev/null || true; }
fresh_run() { fixer_gate_holder=""; fixer_gate_scanned=""; }
ago() { echo $(( $(date +%s) - $1 * 60 )); }

AUTHOR=import:claudeAgent:11111111-1111-1111-1111-111111111111 MAINFIXER=mcp:99999999-9999-9999-9999-999999999999
git init -q --bare "$T/remote.git"; git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
commit() { mkdir -p "$SRC/$(dirname "$1")"; printf '%s\n' "$RANDOM$RANDOM" >> "$SRC/$1"; g add "$1"; g commit -q -m "change $1" -m "$2"; g rev-parse HEAD; }
commit README.md "Thread: $AUTHOR" >/dev/null
g push -q origin HEAD:refs/heads/main
M1=$(g rev-parse HEAD)
# dev: O — its trusted tests fail (the review passed: no blocked review verdict), the author's commit
g checkout -q --detach
O=$(commit src/net/ws-proxy-agent.ts "Thread: $AUTHOR")
g push -q origin HEAD:refs/heads/dev; g fetch -q origin
printf '%s\n' 'trusted tests job: failure' ' FAIL test/ws-direct-report.test.ts > every socket reports itself: src/net/ws-proxy-agent.ts' > "$STATE/sent/$O.findings"
echo "pass 700 1 0 0" > "$DEV_VERDICTS/$O"
echo "[{\"databaseId\":700,\"displayTitle\":\"review $O\",\"status\":\"completed\",\"conclusion\":\"failure\"}]" > "$T/runs.json"
# the one fixer slot is held by a main mainfix chain
MF=$(printf '%040d' 7 | tr 0 e)
echo "$MAINFIXER" > "$STATE/sent/$MF.fixer-mainfix-60a6b0ee0"; set_status "$MAINFIXER" running

# 1. O's fixer request is queued behind the main fixer → the wait episode opens; nobody is told yet
fresh_run
if fixer_gate_pass "$O" blocked; then fail "the gate let a second fixer in"; fi
dev_slot_wait
read -r o0 s0 < "$STATE/dev.slotwait"; [ "$o0" = "$O" ] || fail "no wait episode for O: $(cat "$STATE/dev.slotwait")"
grep -q "dev ${O:0:9}: blocked, no repair, its fix waits for the fixer slot" "$LOG" || fail "episode open not logged"
[ -z "$(sent)" ] || fail "told someone before DEV_SLOT_WAIT_MIN: $(sent)"
echo 'a queued dev block opens a wait episode'

# 2. the head moves (a main→dev merge): O's request is no longer made and is dropped as moot after the TTL; the later
#    head H1 queues the same block. Before DEV_SLOT_WAIT_MIN — but nobody would have O any more → its author at once
g checkout -q main; commit src/main1.ts "Hotfix: x" >/dev/null; g push -q origin HEAD:refs/heads/main
g checkout -q --detach "$O"; g merge -q --no-ff -m "merge main into dev" main
H1=$(g rev-parse HEAD); g push -q origin HEAD:refs/heads/dev; g fetch -q origin
echo "$O $(ago 24)" > "$STATE/dev.slotwait"; s0=$(cut -d' ' -f2 "$STATE/dev.slotwait")
touch -d '-11 minutes' "$FIXER_GATE/queue/$O.blocked"
fresh_run
if fixer_gate_pass "$H1" blocked; then fail "gate"; fi
grep -q "fixer queue: dropped blocked ${O:0:9} — not requested for 10 min (target moot)" "$LOG" || fail "O's request was not dropped"
dev_slot_wait
grep -q "fixer queue drop of blocked ${O:0:9}: the oldest unrepaired blocked dev commit ${O:0:9} has nobody — handed to its author(s) now" "$LOG" \
  || fail "the moot drop left O without an owner, or did not log it: $(tail -3 "$LOG")"
[ "$(sent | grep -c "^slotwait\.$s0\.1\.0	$AUTHOR	")" = 1 ] || fail "O's author was not handed it: $(sent)"
sent | grep -q "Review-Fix-Of: $O" || fail "the hand carries no Review-Fix-Of: task"
sent | grep -q "test/ws-direct-report.test.ts" || fail "the hand carries no findings"
sent | grep -q "mainfix-60a6b0ee0 ${MF:0:9}" || fail "the hand does not say who holds the slot"
[ "$(cut -d' ' -f1 "$STATE/dev.slotwait")" = "$O" ] || fail "the later head took over the episode of the older O"
test ! -e "$STATE/sent/$O.fixer-blocked" || fail "a fixer was woken"
echo 'a moot drop hands the oldest unrepaired commit to its author at once (logged)'

# 3. same hand: once per episode — later runs before 3×DEV_SLOT_WAIT_MIN send nothing more; a further drop logs "its author(s)"
echo "$O $(ago 60)" > "$STATE/dev.slotwait"; s1=$(cut -d' ' -f2 "$STATE/dev.slotwait")
# (a new since = a new episode for the receipts: re-seed the first hand's receipt as delivered under it)
for f in "$STATE/sent/$O.slotwait.$s0".*; do mv "$f" "${f/slotwait.$s0./slotwait.$s1.}"; done
mv "$STATE/sent/$O.slotwait-logged.$s0.1" "$STATE/sent/$O.slotwait-logged.$s1.1"
n0=$(sent | wc -l)
touch -d '-11 minutes' "$FIXER_GATE/queue/$H1.blocked"
fresh_run; fixer_gate_pass "$O" blocked || true   # a fresh request (O queued again) while H1's is dropped
dev_slot_wait; dev_slot_wait
grep -q "fixer queue drop of blocked ${H1:0:9}: the oldest unrepaired blocked dev commit ${O:0:9} has a queued fixer agent ($O.blocked)" "$LOG" \
  || fail "a drop with O still queued did not log its queued fixer: $(tail -3 "$LOG")"
[ "$(sent | wc -l)" = "$n0" ] || fail "re-handed within the same hand: $(sent | tail -2)"
rm -f "$FIXER_GATE/queue/$O.blocked"; echo x > "$FIXER_GATE/dropped"   # a drop while O has no queue but was handed
dev_slot_wait
grep -q "the oldest unrepaired blocked dev commit ${O:0:9} has its author(s), handed it in this episode" "$LOG" || fail "told owner not logged"
[ "$(sent | wc -l)" = "$n0" ] || fail "re-handed after a drop although its author has it"
echo 'one hand per episode; a drop logs who has it'

# 4. still unrepaired 3×DEV_SLOT_WAIT_MIN after it began → handed again (hand 2), once
echo "$O $(ago 95)" > "$STATE/dev.slotwait"; s2=$(cut -d' ' -f2 "$STATE/dev.slotwait")
for f in "$STATE/sent/$O.slotwait.$s1".*; do mv "$f" "${f/slotwait.$s1./slotwait.$s2.}"; done
mv "$STATE/sent/$O.slotwait-logged.$s1.1" "$STATE/sent/$O.slotwait-logged.$s2.1"
dev_slot_wait; dev_slot_wait
[ "$(sent | grep -c "^slotwait\.$s2\.2\.0	$AUTHOR	")" = 1 ] || fail "no single second hand after 3×DEV_SLOT_WAIT_MIN: $(sent)"
sent | grep -q "again (hand 2): it is still unrepaired" || fail "the second hand does not say it is again"
grep -q "dev ${O:0:9}: blocked, no repair, its fix waited 95 min for the fixer slot (held by the fixer agent mainfix-60a6b0ee0" "$LOG" || fail "second hand not logged"
echo 'still unrepaired → handed again once per further 2×DEV_SLOT_WAIT_MIN'

# 5. the author pushes the repair (Review-Fix-Of: O) on dev → the episode ends, logged; no further hand
g checkout -q --detach origin/dev
R=$(commit src/net/ws-proxy-agent.ts "Review-Fix-Of: $O
Thread: $AUTHOR"); g push -q origin HEAD:refs/heads/dev; g fetch -q origin
echo "$O $(ago 200)" > "$STATE/dev.slotwait"
n1=$(sent | wc -l)
dev_slot_wait
test ! -e "$STATE/dev.slotwait" || fail "a repaired commit kept its wait episode"
grep -q "dev ${O:0:9}: its wait for the fixer slot ended after 200 min — repaired by ${R:0:9} on dev" "$LOG" || fail "end not logged: $(tail -2 "$LOG")"
[ "$(sent | wc -l)" = "$n1" ] || fail "a repaired commit was handed"
echo 'a repair ends the episode'

# 6. a blocked REVIEW verdict refused by the dev slot (another dev block's fixer holds it), 31 min: the author gets it;
#    an unreachable author → notice_fallback → the supervisor. Once its own fixer is woken the episode ends.
g checkout -q --detach origin/dev
S=$(commit src/s.ts "Thread: $AUTHOR"); g push -q origin HEAD:refs/heads/dev; g fetch -q origin
echo "blocked 800 1 0 0" > "$DEV_VERDICTS/$S"
printf '%s\n' "review-gate: FINDING #1 route=fixer commit=$S — x" 'review-gate: BLOCKED #1 regression [should]: s drops rows' 'evidence: src/s.ts:1 x' > "$DEV_VERDICTS/$S.review-findings"
touch "$STATE/sent/$S.fixer-deferred"
echo "$AUTHOR" > "$T/gone"
dev_slot_wait
read -r o3 s3 < "$STATE/dev.slotwait"; [ "$o3" = "$S" ] || fail "a dev-slot refusal opened no episode"
echo "$S $(ago 31)" > "$STATE/dev.slotwait"; s3=$(cut -d' ' -f2 "$STATE/dev.slotwait")
fresh_run; dev_slot_wait
[ "$(sent | grep -c "^slotwait\.$s3\.1\.0\.unreached-sup	$SUPERVISOR_THREAD	")" = 1 ] || fail "an unreachable author's hand did not fall back to the supervisor: $(sent | tail -2)"
sent | tail -1 | grep -q "Review-Fix-Of: $S" || fail "fallback lost the task"
sent | tail -1 | grep -q "actions/runs/800" || fail "the hand does not link the blocked run"
SFIX=mcp:33333333-3333-3333-3333-333333333333; echo "$SFIX" > "$STATE/sent/$S.fixer-blocked"; set_status "$SFIX" running
dev_slot_wait
test ! -e "$STATE/dev.slotwait" || fail "its own fixer did not end the wait"
grep -q "dev ${S:0:9}: its wait for the fixer slot ended after 31 min — a fixer agent of its own ($SFIX) has it" "$LOG" || fail "own fixer end not logged"
echo 'a dev-slot refusal is handed too (fallback to the supervisor); its own fixer ends the wait'

# 7. DRY writes nothing
rm -f "$STATE/sent/$S.fixer-blocked"; n2=$(sent | wc -l); l2=$(wc -l < "$LOG")
DRY=1 dev_slot_wait >/dev/null
test ! -e "$STATE/dev.slotwait" && [ "$(sent | wc -l)" = "$n2" ] && [ "$(wc -l < "$LOG")" = "$l2" ] || fail "DRY wrote state"
echo 'dev slot wait checks passed'
