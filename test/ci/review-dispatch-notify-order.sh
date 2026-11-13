#!/usr/bin/env bash
# reviewer → fixer → author (owner 11-12): a blocked review wakes a fixer and nobody else; the authors hear of it
# only when the fixer path failed (thread ended with no fix, launch failures, fix keeps failing its tests, budget),
# or the revert of their commit is due / done. Fixer reports stay in the dispatch log. Duplicate fixes are skipped.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
# Any command that is not found — a dispatcher helper the test did not extract — fails the whole test at once, even
# inside an if / || condition (review of 02828988f #7: "culprits_repaired: command not found" printed, test exited 0).
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
FIXER_ENDED_GRACE_MIN=0   # these cases judge receipts written a moment ago
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh ROOT=$PWD
fns() { local n b; for n in "$@"; do b=$(sed -n "/^$n() {/,/^}/p; /^$n() { .*}\$/p" "$D")  # a missing helper fails the test (it used to only print to stderr)
  if [ -z "$b" ]; then printf '{ echo "fns: helper %s not found in %s" >&2; exit 1; }\n' "$n" "$D"; else printf '%s\n' "$b"; fi; done; }
eval "$(fns repair_effective fix_reverted thread_of fixer_receipt_thread range_threads culprit_threads notify_threads devfix_fix_of fixer_ended launch_failed \
  dev_round_pending dev_carries_fix hotfix_fix_pushed named_files blocked_author_reason dev_blocked \
  or_supervisor norm_tid finding_blocks finding_meta finding_route review_round_route route_reason attribute_finding \
  attribution findings_subset att_of culprit_lines notify_attributed author_fixed author_turn split_fixer_failed \
  split_fixer dev_blocked_split revert_after_for own_findings fyi_author culprits_repaired)"
eval "$(sed -n '/^digest_file() {/p; /^digest_add() {/,/^}/p' scripts/ci/review-notify.sh)"   # fyi_author → the authors' digest
SUPERVISOR_THREAD=import:claudeAgent:supervisor DISPATCH_THREAD=00000000-0000-4000-8000-0000000000c1 AUTHOR_FIX_WINDOW_SEC=3600
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DEV=dev REPO=test/repo DEV_REVERT_AFTER_SEC=3600 FIXER_GATE_STALE_MIN=90
FIXER_GATE=$STATE/fixer-gate; mkdir -p "$STATE/sent" "$FIXER_GATE/queue"
LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
A=mcp:11111111-1111-1111-1111-111111111111 B=mcp:22222222-2222-2222-2222-222222222222
git init -q --bare "$T/remote.git"
git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
commit() { # commit <file> <thread> [extra trailer line]
  mkdir -p "$SRC/$(dirname "$1")"; echo "$RANDOM" >> "$SRC/$1"; g add "$1"
  g commit -q -m "change $1" -m "Thread: $2${3:+
$3}"; g rev-parse HEAD
}
commit README.md "$A" >/dev/null
g push -q origin HEAD:refs/heads/main
S=$(commit src/a.ts "$A")          # the blocked dev sha: A's commit on src/a.ts
commit src/b.ts "$B" >/dev/null    # B's unrelated commit (B must never hear of a.ts findings)
S=$(g rev-parse HEAD)
g push -q origin HEAD:refs/heads/dev; g fetch -q origin
F="review-gate: BLOCKED #1 [blocker] src/a.ts:3 does the wrong thing"

# stubs: the gate, budget and T3 have their own tests
woken=$T/woken; sent=$T/sent-notices
wake_fixer() { echo "$1 $2" >> "$woken"; [ -n "${WAKE_FAIL:-}" ] && { echo x >> "$STATE/sent/$1.$2.launchfail"; return 1; }; echo "$THREAD_ID" > "$STATE/sent/$1.fixer-$2"; }
notify_best_effort() { echo "$2 $3" >> "$sent"; }
notify() { [ -e "$T/notify-fails" ] && return 1; [ -e "$STATE/sent/$1.$2" ] && return 0; echo "$2 $3" >> "$sent"; touch "$STATE/sent/$1.$2"; }
dev_fixer_free() { [ -z "${BUSY:-}" ]; }
fix_budget_ok() { return 0; }
dev_fixer_claim() { :; }
fixer_phrase() { echo phrase; }
fixer_thread_state() { echo "$THREAD_STATE"; }
gh() { printf '%s\n' "${PENDING:-}"; }
THREAD_ID=mcp:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa THREAD_STATE=running
cul=$(culprit_threads "$S" "$F")
test "$cul" = "$A"
reset() { rm -f "$woken" "$sent" "$LOG"; rm -rf "$STATE/sent"; mkdir -p "$STATE/sent"; rm -f "$FIXER_GATE"/queue/*; unset pending_titles; }

# 1. blocked → the fixer is woken, no author is told
reset
dev_blocked "$S" "$F" "$cul" run-url task
test "$(cat "$woken")" = "$S blocked"
test ! -e "$sent"
grep -q 'authors not woken' "$LOG"
# … and while it works, later runs tell nobody either
dev_blocked "$S" "$F" "$cul" run-url task
test ! -e "$sent"
echo 'blocked: fixer only'

# 2. fixer busy (another blocked sha holds the slot) / queued behind another fixer → only log
reset; BUSY=1
dev_blocked "$S" "$F" "$cul" run-url task
test ! -e "$woken"; test ! -e "$sent"
unset BUSY; touch "$FIXER_GATE/queue/$S.blocked"
wake_fixer() { echo "$1 $2" >> "$woken"; return 1; }   # gate: queued
dev_blocked "$S" "$F" "$cul" run-url task
test ! -e "$sent"
wake_fixer() { echo "$1 $2" >> "$woken"; [ -n "${WAKE_FAIL:-}" ] && { echo x >> "$STATE/sent/$1.$2.launchfail"; return 1; }; echo "$THREAD_ID" > "$STATE/sent/$1.fixer-$2"; }
echo 'busy / queued fixer: no author notice'

# 3. the fixer's thread ended (interrupted / archived) with no devfix pushed → the culprit author, once
reset
dev_blocked "$S" "$F" "$cul" run-url task
THREAD_STATE=interrupted
dev_blocked "$S" "$F" "$cul" run-url task
test "$(cat "$sent")" = "fixfailed.0 $A"
# the real notify() dedupes per key: the same key on the next run is the same receipt
dev_blocked "$S" "$F" "$cul" run-url task
test "$(sort -u "$sent" | wc -l)" -eq 1
# … but an ended fixer whose devfix branch is pushed is still on its way: nobody told
reset; THREAD_STATE=running
dev_blocked "$S" "$F" "$cul" run-url task
g checkout -q -b fix "$S"; commit src/a.ts "$THREAD_ID" "Review-Fix-Of: $S" >/dev/null
g push -q origin "HEAD:refs/heads/devfix/${S:0:12}"; g checkout -q main; g fetch -q origin
THREAD_STATE=archived
dev_blocked "$S" "$F" "$cul" run-url task
test ! -e "$sent"
g push -q origin --delete "devfix/${S:0:12}"; g fetch -q --prune origin
THREAD_STATE=running
echo 'ended fixer without devfix: author told once'

# 3b. no fixer can be started: one failed launch is retried silently, the second tells the author
reset; WAKE_FAIL=1
dev_blocked "$S" "$F" "$cul" run-url task
test ! -e "$sent"
dev_blocked "$S" "$F" "$cul" run-url task
test "$(cat "$sent")" = "fixfailed.0 $A"
unset WAKE_FAIL
echo 'launch failures: author told after the second'

# 3c. round budget spent → it ends: no fixer and nobody told (owner 11-12; re-check of 6616b3138 #1/#2)
reset; echo "3 3" > "$STATE/sent/$S.budget-spent"
fix_budget_ok() { return 1; }
dev_blocked "$S" "$F" "$cul" run-url task
test ! -e "$woken"; test ! -e "$sent"
fix_budget_ok() { return 0; }
echo 'budget spent: nobody told'

# 4. review clean, only the trusted tests failed (prettier / lint) → fixer only
reset
dev_blocked "$S" "trusted tests job: failure
##[error]Code style issues found in src/a.ts. Run Prettier." "$cul" run-url task
test "$(cat "$woken")" = "$S blocked"; test ! -e "$sent"
echo 'tests-only failure: fixer only'

# 5. fixer reports go to the dispatch log, not to any thread
out=$(printf 'fixed #1\n' | STATE=$STATE bash -c "$(cat scripts/ci/review-notify.sh)" -- "$S" fixer-report log 2>&1)
test -z "$out"
grep -q "fixer-report ${S:0:9}: fixed #1" "$LOG"
test -z "$(ls "$STATE/sent" | grep fixer-report || true)"
grep -q 'Do NOT message the authors' "$D"
! grep -q 'fixer-report-<thread>' "$D" || { echo "negative check failed: test/ci/review-dispatch-notify-order.sh:130" >&2; exit 1; }
echo 'fixer report: log only'

# 6. duplicate fix: dev beyond S already carries "Review-Fix-Of: S" → no fixer, logged once
reset
g checkout -q -B devw origin/dev
commit src/a.ts "$A" "Review-Fix-Of: $S" >/dev/null
g push -q origin HEAD:refs/heads/dev; g fetch -q origin
dev_blocked "$S" "$F" "$cul" run-url task
dev_blocked "$S" "$F" "$cul" run-url task
test ! -e "$woken"; test ! -e "$sent"
test "$(grep -c 'already carries a fix' "$LOG")" -eq 1
# … the author's own later commit on the named file counts only while a newer dev round is in review
g reset -q --hard "$S"; commit src/a.ts "$A" >/dev/null; N=$(g rev-parse HEAD)
g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin
reset; PENDING="review $N"
dev_blocked "$S" "$F" "$cul" run-url task
test ! -e "$woken"; grep -q "author's ${N:0:9}" "$LOG"
reset; PENDING=""
dev_blocked "$S" "$F" "$cul" run-url task
test "$(cat "$woken")" = "$S blocked"
# another author's later commit on the same file is no fix of S
g reset -q --hard "$S"; commit src/a.ts "$B" >/dev/null; N=$(g rev-parse HEAD)
g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin
reset; PENDING="review $N"
dev_blocked "$S" "$F" "$cul" run-url task
test "$(cat "$woken")" = "$S blocked"
g checkout -q main
echo 'duplicate fix: skipped'

# 7. hotfix re-check: a pushed Review-Fix-Of: H commit closes it without the author
H=$(g rev-parse origin/main)
! hotfix_fix_pushed "$H" >/dev/null || { echo "negative check failed: test/ci/review-dispatch-notify-order.sh:162" >&2; exit 1; }
g checkout -q -B mainw origin/main; commit src/h.ts "$A" "Review-Fix-Of: $H" >/dev/null
g push -q origin HEAD:refs/heads/main; g fetch -q origin; g checkout -q main
test "$(hotfix_fix_pushed "$H")" = "$(g rev-parse origin/main)"
echo 'hotfix fix detection'

# 8. revert: the warning before and the notice after reach the culprit author only
warn=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('    # the revert is about to hit the culprits')
b = s.index('\n    fi\n', s.index('touch "$STATE/sent/dev.revertwarn.$since"', a)) + len('\n    fi\n')
print(s[a:b])
PY
)
rev=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('    if [ $((now - since)) -ge "$revert_after" ] && [ ! -e "$STATE/sent/$sha.reverted" ]; then')
b = s.index('\n  else\n    f=$(findings', a)
print(s[a:b])
PY
)
eval "$(fns dispatch_msg)"; DISPATCH_THREAD=$A DEV_REVERT_WARN_SEC=900 WORK=$T/work key_prefix=""
g fetch -q origin; g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
sha=$S f=$F url=run-url since_f=$STATE/dev.blocked_since
reset; now=$(date +%s); since=$((now - 3000))
eval "$warn"; eval "$warn"
test "$(cat "$sent")" = "revertwarn-$since.revertsoon.0 $A"
reset; since=$((now - 600)); eval "$warn"; test ! -e "$sent"   # not yet due
# a failed delivery does not close the episode: the next run retries and then marks it warned
reset; since=$((now - 3000)); touch "$T/notify-fails"; eval "$warn"
test ! -e "$sent"; test ! -e "$STATE/sent/dev.revertwarn.$since"
rm -f "$T/notify-fails"; eval "$warn"; eval "$warn"
test "$(cat "$sent")" = "revertwarn-$since.revertsoon.0 $A"; test -e "$STATE/sent/dev.revertwarn.$since"
# terminal revert notices go through the outbox (re-check of 7b7b4b5c2 #1): the real notify_best_effort, one tick = rev + flush
eval "$(fns notify_best_effort outbox_add revert_notices_flush)"; notify_outbox=""; OUTBOX=$STATE/outbox REVERT_NOTICE_TRIES=10
type revert_notices_flush >/dev/null 2>&1 || revert_notices_flush() { :; }
tick() { eval "$rev"; revert_notices_flush; }
reset; rm -rf "$OUTBOX"; since=$((now - 3700)); echo "$since" > "$since_f"
# re-check of f0d573631 #9: every notice is queued before the revert is recorded done (reverted marker / episode receipt)
rm -f "$T/order"; eval "real_$(declare -f outbox_add)"
outbox_add() { if [ -e "$STATE/sent/$sha.reverted" ] || [ -e "$STATE/sent/$sha.revert-episode" ]; then echo early >> "$T/order"; fi; real_outbox_add "$@"; }
tick
test ! -e "$T/order"
eval "$(declare -f real_outbox_add | sed '1s/real_outbox_add/outbox_add/')"
grep -q 'REVERTED on dev' "$LOG"
test "$(cut -d' ' -f1,2 "$sent")" = "reverted $A"
test ! -e "$since_f"   # every notice out → the episode closed
g fetch -q origin; git -C "$SRC" log -1 --format=%s origin/dev | grep -q '^revert on dev'
# the dispatcher's own revert says "This reverts commit <full sha>" per commit, so fix_reverted sees it (re-check of 826fd1034 #7)
rc=$(git -C "$SRC" log -1 --format=%B origin/dev | sed -nE 's/^This reverts commit ([0-9a-f]{40})\.$/\1/p' | head -1)
test -n "$rc"; git -C "$SRC" merge-base --is-ancestor "$rc" "$S"
fix_reverted "$rc" origin/dev
git -C "$SRC" log -1 --format=%B origin/dev | grep -q '^This reverts commit [0-9a-f]\{40\}\.$'
git -C "$SRC" log -1 --format=%B origin/dev | grep -qx 'Loop: review-dispatch'
echo 'revert: warned before, told after'
# a failed delivery after the git action: the action runs once, the notice is retried next tick, the episode closes after it
for path in reverted conflict; do
  g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
  reset; rm -rf "$OUTBOX"; since=$((now - 3700)); echo "$since" > "$since_f"; touch "$T/notify-fails"
  if [ "$path" = conflict ]; then git() { if [[ " $* " == *" revert --no-commit "* ]]; then return 1; fi; command git "$@"; }; fi
  tick
  test ! -e "$sent"; test -e "$STATE/sent/$sha.reverted"
  if [ "$path" = reverted ]; then test -e "$since_f"; fi   # not closed while its notice is undelivered
  rm -f "$T/notify-fails"; g fetch -q origin; tick; tick
  test "$(grep -cE '^(REVERTED on dev|revert on dev .* conflicted)' "$LOG")" -eq 1   # git action once
  if [ "$path" = conflict ]; then test "$(cat "$sent")" = "revertfail.revertfail.0 $A"; else test "$(cat "$sent")" = "reverted $A"; test ! -e "$since_f"; fi
  unset -f git
done
# undeliverable for REVERT_NOTICE_TRIES runs → given up, the supervisor told
reset; rm -rf "$OUTBOX"; REVERT_NOTICE_TRIES=2
eval "real_$(declare -f notify)"; notify() { [ "$3" = "$B" ] && return 1; real_notify "$@"; }   # only B is unreachable
outbox_add "$S" "$S" k "$B" msg; revert_notices_flush; test ! -e "$sent"; revert_notices_flush
eval "$(declare -f real_notify | sed '1s/real_notify/notify/')"
test -z "$(ls -A "$OUTBOX/$S")"; grep -q 'given up, supervisor told' "$LOG"; test "$(cat "$sent")" = "k.giveup $SUPERVISOR_THREAD"
# … and when the supervisor is unreachable too, the notice stays queued (re-check of 826fd1034 #8)
reset; rm -rf "$OUTBOX"; REVERT_NOTICE_TRIES=2; echo 123 > "$since_f"; echo 123 > "$STATE/sent/$S.revert-episode"
notify() { return 1; }
outbox_add "$S" "$S" k "$B" msg; revert_notices_flush; revert_notices_flush; revert_notices_flush
test -n "$(ls -A "$OUTBOX/$S")"; test -e "$since_f"; grep -q 'supervisor is unreachable too' "$LOG"
eval "$(declare -f real_notify | sed '1s/real_notify/notify/')"; revert_notices_flush
test -z "$(ls -A "$OUTBOX/$S" 2>/dev/null)"; test ! -e "$since_f"
# an archived recipient (notify_outcome=skipped) is not a delivery: the supervisor gets it; until then it stays queued
# (re-check of e721f39a0 #6)
reset; rm -rf "$OUTBOX"; REVERT_NOTICE_TRIES=10; echo 123 > "$since_f"; echo 123 > "$STATE/sent/$S.revert-episode"
SUPDOWN=1
notify() { notify_outcome=sent
  if [ "$3" = "$B" ]; then notify_outcome=skipped; return 0; fi
  if [ "$3" = "$SUPERVISOR_THREAD" ] && [ -n "$SUPDOWN" ]; then notify_outcome=undelivered; return 1; fi
  echo "$2 $3" >> "$sent"; }
outbox_add "$S" "$S" k "$B" msg; revert_notices_flush; revert_notices_flush
test -n "$(ls -A "$OUTBOX/$S")"; test -e "$since_f"; test ! -e "$sent"; grep -q "is archived — forwarding to the supervisor" "$LOG"
SUPDOWN=; revert_notices_flush
test "$(cat "$sent")" = "k.giveup $SUPERVISOR_THREAD"; test -z "$(ls -A "$OUTBOX/$S" 2>/dev/null)"; test ! -e "$since_f"
eval "$(declare -f real_notify | sed '1s/real_notify/notify/')"
REVERT_NOTICE_TRIES=10
notify_best_effort() { echo "$2 $3" >> "$sent"; }
g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
echo 'terminal revert notices: retried until delivered, git action once'

# 9. devfix trusted tests failed: the first failure is the fixer's (testsfail), a second fix head failing tells the author
land=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('      # Authors only when the fix keeps failing')
b = s.index('      continue', a)
print(s[a:b])
PY
)
g checkout -q -B fixw "$S"
fh=$(commit src/a.ts "$THREAD_ID" "Review-Fix-Of: $S"); fs=$S fref=devfix/${S:0:12} frun=9 gaps=""
reset
for tick in 1 2; do eval "$land"; done
test ! -e "$sent"
echo "$THREAD_ID" > "$STATE/sent/$fh.fixer-testsfail"; THREAD_STATE=running
eval "$land"; test ! -e "$sent"          # its testsfail fixer is at work
fh=$(commit src/a.ts "$THREAD_ID" "Review-Fix-Of: $S")
eval "$land"; eval "$land"
test "$(sort -u "$sent")" = "fixfailed.0 $A"
# a testsfail fixer that ended without a new head tells the author too
reset; fh=$(commit src/a.ts "$THREAD_ID" "Review-Fix-Of: $S")
echo "$THREAD_ID" > "$STATE/sent/$fh.fixer-testsfail"; THREAD_STATE=archived
eval "$land"; test "$(cat "$sent")" = "fixfailed.0 $A"
THREAD_STATE=running; g checkout -q main
echo 'devfix tests failing: author told on the second failure / ended fixer'
# re-check of 852eea2c5 #7: with the REAL notify, a skipped (archived) receipt stays skipped on later runs; recipient and
# supervisor archived → the CI owner gets it; all three archived → logged ERROR, dropped (episode closes)
source "$ROOT/scripts/ci/review-notify.sh"
OWNER=00000000-0000-4000-8000-0000000000c1
for owner_ok in 1 0; do
  rm -rf "$STATE/sent" "$OUTBOX"; mkdir -p "$STATE/sent"; : > "$LOG"; rm -f "$T/t3sent"
  echo 123 > "$since_f"; echo 123 > "$STATE/sent/$S.revert-episode"; REVERT_NOTICE_TRIES=10; DISPATCH_THREAD=$OWNER
  t3() { if [ "$3" = "$OWNER" ] && [ "$owner_ok" = 1 ]; then cat > /dev/null; echo "$3" >> "$T/t3sent"; return 0; fi; cat > /dev/null; echo "Thread $3 is archived" >&2; return 1; }
  timeout() { shift; "$@"; }
  outbox_add "$S" "$S" k "$B" msg
  revert_notices_flush; revert_notices_flush; revert_notices_flush
  test ! -e "$since_f"   # closed either way — never held open forever
  if [ "$owner_ok" = 1 ]; then test "$(cat "$T/t3sent")" = "$OWNER"; ! grep -q 'all unreachable' "$LOG" || { echo "negative check failed: test/ci/review-dispatch-notify-order.sh:300" >&2; exit 1; }
  else test ! -e "$T/t3sent"; grep -q 'ERROR revert notice k .*all unreachable' "$LOG"; fi
  test -z "$(ls -A "$OUTBOX/$S" 2>/dev/null)"
done
unset -f t3 timeout
echo 'archived recipient + supervisor: the CI owner, else a logged drop'
# re-check of 0b463b6c0 #7: a notice queued before its git push waits for the push, is sent once $DEV has it, and expires
# unsent if the push never happened
rm -rf "$STATE/sent" "$OUTBOX"; mkdir -p "$STATE/sent"; : > "$LOG"; rm -f "$sent"
eval "$(fns outbox_add)"
notify() { echo "$2 $3" >> "$sent"; notify_outcome=sent; }
g checkout -q -B pushw origin/dev; PC=$(commit src/p.ts "$A"); g checkout -q main   # not on origin/dev yet
notify_outbox=$S notify_outbox_require=$PC; outbox_add "$S" "$S" k "$B" msg; notify_outbox="" notify_outbox_require=""
revert_notices_flush; test ! -e "$sent"; test -n "$(ls -A "$OUTBOX/$S")"   # waits for the push
g push -q -f origin "$PC:refs/heads/dev"; g fetch -q origin
revert_notices_flush; test "$(cat "$sent")" = "k $B"
rm -rf "$OUTBOX"; rm -f "$sent"; g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
notify_outbox=$S notify_outbox_require=$PC; outbox_add "$S" "$S" k2 "$B" msg; notify_outbox="" notify_outbox_require=""
f=$(ls "$OUTBOX/$S"/*.require); echo "$PC $(( $(date +%s) - 4000 ))" > "$f"   # queued over 30 min ago, never pushed
revert_notices_flush; test ! -e "$sent"; grep -q 'never reached dev — dropped' "$LOG"
eval "$(declare -f real_notify | sed '1s/real_notify/notify/')" 2>/dev/null || true
echo 'notices queued before the push: sent after it, dropped if it never happened'
echo 'notify-order checks passed'
