#!/usr/bin/env bash
# The reviewer routes each blocked finding to its author or the fixer (owner 11-12), with findings attributed per
# commit → Thread: (each author gets only their own; unattributable → fixer / supervisor, never a broadcast).
# Plus: a reverted Review-Fix-Of commit is no fix; ended conflict fixers escalate once.
set -euo pipefail
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }   # gh-cache.sh (the per-run memo of review-dispatch.sh): here the fake gh itself
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
# Any command that is not found — a dispatcher helper the test did not extract — fails the whole test at once, even
# inside an if / || condition (review of 02828988f #7: "culprits_repaired: command not found" printed, test exited 0).
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
FIXER_ENDED_GRACE_MIN=0   # these cases judge receipts written a moment ago
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fns() { local n b; for n in "$@"; do b=$(sed -n "/^$n() {/,/^}/p; /^$n() { .*}\$/p" "$D")  # a missing helper fails the test (it used to only print to stderr)
  if [ -z "$b" ]; then printf '{ echo "fns: helper %s not found in %s" >&2; exit 1; }\n' "$n" "$D"; else printf '%s\n' "$b"; fi; done; }
eval "$(fns repair_effective author_group_key findings_cap thread_of fixer_receipt_thread range_threads culprit_threads or_supervisor notify_threads devfix_fix_of fixer_ended launch_failed \
  dev_round_pending dev_carries_fix fix_reverted hotfix_fix_pushed escalate_ended_fixer named_files blocked_author_reason \
  dev_blocked norm_tid finding_blocks finding_meta finding_route review_round_route route_reason attribute_finding \
  attribution findings_subset att_of culprit_lines notify_attributed author_fixed author_turn split_fixer_failed \
  split_fixer dev_blocked_split revert_after_for own_findings fyi_author culprits_repaired att_threads)"
eval "$(sed -n '/^digest_file() {/p; /^digest_add() {/,/^}/p' scripts/ci/review-notify.sh)"   # fyi_author → the authors' digest
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DEV=dev REPO=test/repo DEV_REVERT_AFTER_SEC=3600 FIXER_GATE_STALE_MIN=90 AUTHOR_FIX_WINDOW_SEC=3600
SUPERVISOR_THREAD=import:claudeAgent:sup DISPATCH_THREAD=00000000-0000-4000-8000-0000000000c1 key_prefix=""
FIXER_GATE=$STATE/fixer-gate; mkdir -p "$STATE/sent" "$FIXER_GATE/queue"
LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
A=mcp:11111111-1111-1111-1111-111111111111 B=mcp:22222222-2222-2222-2222-222222222222
git init -q --bare "$T/remote.git"
git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
commit() { # commit <file> <thread> [extra trailer line] → sha (writes 5 lines so evidence lines can be blamed)
  mkdir -p "$SRC/$(dirname "$1")"; printf '%s\n' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" > "$SRC/$1"; g add "$1"
  g commit -q -m "change $1" -m "Thread: $2${3:+
$3}"; g rev-parse HEAD
}
commit README.md "$A" >/dev/null
g push -q origin HEAD:refs/heads/main
CA=$(commit src/a.ts "$A")          # A's commit
CB=$(commit src/b.ts "$B")          # B's commit
S=$(g rev-parse HEAD)
g push -q origin HEAD:refs/heads/dev; g fetch -q origin
# two findings, one in each author's file; the reviewer routes both to the author
F2="review-gate: FINDING #1 route=author commit=- — needs A's intent
review-gate: FINDING #2 route=author commit=- — needs B's intent
review-gate: ROUTE author — needs A's intent
review-gate: BLOCKED #1 missed-class [blocker]: same bug in a.ts siblings
evidence: src/a.ts:3 drops the row
review-gate: BLOCKED #2 ducktape [should]: patch hides b
evidence: src/b.ts:2 swallows the error"

woken=$T/woken; sent=$T/sent
wake_fixer() { [ -e "$STATE/sent/$1.fixer-$2" ] && return 0; echo "$1 $2" >> "$woken"; printf '%s\n' "$4" > "$T/task-$2"; echo "$THREAD_ID" > "$STATE/sent/$1.fixer-$2"; }
notify_best_effort() { echo "$2 $3" >> "$sent"; printf '%s\n' "$4" > "$T/msg-$2"; }
UNWAKEABLE=""
notify() { # the real notify's outcome contract: sent | skipped (archived) | undelivered
  if [ -n "$UNWAKEABLE" ] && grep -qxF "$3" <<<"$UNWAKEABLE"; then notify_outcome=skipped; return 0; fi
  echo "$2 $3" >> "$sent"; printf '%s\n' "$4" > "$T/msg-${3##*:}"; notify_outcome=sent; touch "$STATE/sent/$1.$2"
}
dev_fixer_free() { return 0; }
BUDGET_OK=1; fix_budget_ok() { [ "$BUDGET_OK" = 1 ]; }
dev_fixer_claim() { :; }
fixer_phrase() { echo phrase; }
fixer_thread_state() { echo "$THREAD_STATE"; }
gh() { printf '%s\n' "${PENDING:-}"; }
THREAD_ID=mcp:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa THREAD_STATE=running
reset() { rm -f "$woken" "$sent" "$LOG" "$T"/msg-* "$T"/task-*; rm -rf "$STATE/sent"; mkdir -p "$STATE/sent"; rm -f "$FIXER_GATE"/queue/*; UNWAKEABLE=""; BUDGET_OK=1; }

# 0. parsing: the per-finding route and commit; missing route → fixer
test "$(finding_meta "$F2" 2 route)" = author
test "$(finding_meta "$F2" 1 commit)" = -
test "$(finding_route "review-gate: BLOCKED #1 regression [blocker]: x" 1)" = fixer
test "$(review_round_route "$F2")" = author
test "$(review_round_route "trusted tests job: failure
review-gate: ROUTE author — x")" = fixer
echo 'route parsing'

# 1. attribution: each finding → its own commit / thread (blame of the evidence line)
att=$(attribution "$S" "$F2")
test "$att" = "1 author $CA $A
2 author $CB $B"
# the reviewer's commit field outside the range is ignored → blame decides
OUT=$(g rev-parse origin/main)
test "$(attribute_finding "$S" "evidence: src/b.ts:2 x" "$OUT")" = "$CB $B"
# … a commit field inside the range wins over blame
test "$(attribute_finding "$S" "evidence: src/b.ts:2 x" "${CA:0:12}")" = "$CA $A"
echo 'attribution: commit field (range-checked) → blame → single-thread file'

# 2. route=author, two authors → each thread gets only its own finding, no fixer
reset
dev_blocked "$S" "$F2" "" run-url task
test ! -e "$woken"
test "$(sort "$sent" | cut -d' ' -f2 | tr '\n' ' ')" = "$A $B "
grep -q 'a.ts siblings' "$T/msg-${A##*:}"; ! grep -q 'b.ts' "$T/msg-${A##*:}" || { echo "negative check failed: test/ci/review-dispatch-route.sh:90" >&2; exit 1; }
grep -q 'patch hides b' "$T/msg-${B##*:}"; ! grep -q 'a.ts siblings' "$T/msg-${B##*:}" || { echo "negative check failed: test/ci/review-dispatch-route.sh:91" >&2; exit 1; }
# supervisor 11-12: every finding's culprit commit already repaired on dev (one full sha, one short) → no fixer, nobody told
reset
g checkout -q -B devw origin/dev; commit src/a.ts "$A" "Review-Fix-Of: $CA" >/dev/null; commit src/b.ts "$B" "Review-Fix-Of: ${CB:0:9}" >/dev/null
g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
dev_blocked "$S" "$F2" "" run-url task
test ! -e "$woken"; test ! -e "$sent"; grep -q 'already repairs its culprit commit' "$LOG"
# only one culprit repaired → per finding (supervisor 11-14, tralyx 26b73ac1b / 33b2b479b): A's #1 (repaired on dev) is dropped
# and logged with its repair; only B hears, of #2 only
reset
g checkout -q -B devw "$S"; RA=$(commit src/a.ts "$A" "Review-Fix-Of: $CA")
g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
dev_blocked "$S" "$F2" "" run-url task
! grep -q 'already repairs its culprit commit(s) (' "$LOG" || { echo "negative check failed: the partial case is no full dupfix" >&2; exit 1; }
grep -q "dropped finding(s) 1 — dev already repairs their culprit commit(s) (#1: ${RA:0:9} repairs ${CA:0:9};); routing only 2" "$LOG"
test "$(cut -d' ' -f2 "$sent" | sort -u)" = "$B"; test ! -e "$T/msg-${A##*:}"
grep -q 'patch hides b' "$T/msg-${B##*:}"; ! grep -q 'a.ts siblings' "$T/msg-${B##*:}" || { echo "negative check failed: B got A's repaired finding" >&2; exit 1; }
g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
echo 'blocked head whose culprit commits dev already repairs: no fixer, nobody told; partly repaired: only the open findings are routed'
# dev without that repair again: A's #1 is open now and routed to A; B is not told twice; no fixer
dev_blocked "$S" "$F2" "" run-url task
test ! -e "$woken"; test "$(wc -l < "$sent")" -eq 2; grep -q 'a.ts siblings' "$T/msg-${A##*:}"
# later runs inside the window: nobody new
dev_blocked "$S" "$F2" "" run-url task
test "$(wc -l < "$sent")" -eq 2
echo 'route=author: each author only their own findings, no fixer'

# 3. author silent 60 min → the fixer gets that author's findings (authorto), on dev, with the culprit commit
for m in "$STATE"/sent/"$S".route-author.*; do echo "author $(( $(date +%s) - 3700 ))" > "$m"; done
dev_blocked "$S" "$F2" "" run-url task
KA=$(author_group_key "$A" 1) KB=$(author_group_key "$B" 2)
test "$(sort "$woken")" = "$(printf '%s\n' "$S $KA" "$S $KB" | sort)"
grep -q 'author did not fix' "$LOG"
grep -q "commit ${CA:0:12}" "$T/task-$KA"; grep -q 'HEAD:refs/heads/dev' "$T/task-$KA"
grep -q 'a.ts siblings' "$T/task-$KA"; ! grep -q 'patch hides b' "$T/task-$KA" || { echo "negative check failed: test/ci/review-dispatch-route.sh:119" >&2; exit 1; }
echo 'author silent 60 min → fixer'
# … unless the author pushed their repair meanwhile (their own commit with Review-Fix-Of: S)
reset
dev_blocked "$S" "$F2" "" run-url task
g checkout -q -B devw origin/dev; commit src/a.ts "$A" "Review-Fix-Of: $S" >/dev/null; commit src/b.ts "$B" "Review-Fix-Of: $S" >/dev/null
g push -q origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
for m in "$STATE"/sent/"$S".route-author.*; do echo "author $(( $(date +%s) - 3700 ))" > "$m"; done
dev_blocked "$S" "$F2" "" run-url task
test ! -e "$woken"; grep -q 'pushed .* for their findings' "$LOG"
g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
echo 'author fixed in time → no fixer'

# 3a. re-check of 32e2af473 #1/#2: staggered timeouts — A times out first (fixer for A), B later → B gets its OWN fixer
reset
dev_blocked "$S" "$F2" "" run-url task
echo "author $(( $(date +%s) - 3700 ))" > "$STATE/sent/$S.route-author.${A//[^A-Za-z0-9-]/_}"
dev_blocked "$S" "$F2" "" run-url task
test "$(cat "$woken")" = "$S $KA"
echo "author $(( $(date +%s) - 3700 ))" > "$STATE/sent/$S.route-author.${B//[^A-Za-z0-9-]/_}"
dev_blocked "$S" "$F2" "" run-url task
test "$(tail -1 "$woken")" = "$S $KB"; test "$(wc -l < "$woken")" -eq 2
grep -q 'patch hides b' "$T/task-$KB"; ! grep -q 'a.ts siblings' "$T/task-$KB" || { echo "negative check failed: test/ci/review-dispatch-route.sh:141" >&2; exit 1; }
# the gate knows the per-group keys (receipt regex, priority)
grep -qF '(landmain|mainmerge|train|authorto|mainfix)-[0-9a-f]{9}' "$D"; grep -qF 'blocked|authorto|authorto-*) echo 4' "$D"
echo 'staggered author timeouts → one fixer per group'

# 3b. re-check of 32e2af473 #3: an author commit merely touching a named file is no repair — the fixer still comes
reset
dev_blocked "$S" "$F2" "" run-url task
g checkout -q -B devw origin/dev; commit src/a.ts "$A" >/dev/null
g push -q origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
if author_fixed "$S" "$A" origin/dev >/dev/null; then echo "unexpected: a file touch counted as the author's repair" >&2; exit 1; fi
echo "author $(( $(date +%s) - 3700 ))" > "$STATE/sent/$S.route-author.${A//[^A-Za-z0-9-]/_}"
dev_blocked "$S" "$F2" "" run-url task
test "$(cat "$woken")" = "$S $KA"
g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
echo 'file touch is no author repair'

# 3c. re-check of 32e2af473 #4: fixer C's repair of S does not hide fixer A's failure (matched by the receipt's thread)
reset
C=mcp:cccccccc-cccc-cccc-cccc-cccccccccccc
g checkout -q -B devw origin/dev; commit src/b.ts "$C" "Review-Fix-Of: $S
Loop: dev-fixer" >/dev/null
g push -q origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
echo "$C" > "$STATE/sent/$S.fixer-blocked"; echo "$THREAD_ID" > "$STATE/sent/$S.fixer-$KA"
THREAD_STATE=completed
test -z "$(split_fixer_failed "$S" blocked)"              # C delivered its own group
test -n "$(split_fixer_failed "$S" "$KA")"                # A ended without its repair → escalated
# 3d. #5: a reverted repair is no repair for these detectors either
g checkout -q -B devw origin/dev; R=$(commit src/a.ts "$THREAD_ID" "Review-Fix-Of: $S
Loop: dev-fixer"); g push -q origin HEAD:refs/heads/dev; g fetch -q origin
test -z "$(split_fixer_failed "$S" "$KA")"
g revert --no-edit "$R" >/dev/null; g push -q origin HEAD:refs/heads/dev; g fetch -q origin
test -n "$(split_fixer_failed "$S" "$KA")"
R=$(commit src/a.ts "$A" "Review-Fix-Of: $S"); g push -q origin HEAD:refs/heads/dev; g fetch -q origin
test "$(author_fixed "$S" "$A" origin/dev)" = "$R"
g revert --no-edit "$R" >/dev/null; g push -q origin HEAD:refs/heads/dev; g fetch -q origin
if author_fixed "$S" "$A" origin/dev >/dev/null; then echo "unexpected: a reverted author repair still counts" >&2; exit 1; fi
THREAD_STATE=running; g checkout -q main; g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
echo 'repairs matched to their fixer thread; reverted repairs never count'

# 4. author thread not wakeable (archived) → fixer at once for that author's finding only; the other author keeps theirs
reset; UNWAKEABLE=$A
dev_blocked "$S" "$F2" "" run-url task
test "$(cat "$woken")" = "$S blocked"
grep -q 'a.ts siblings' "$T/task-blocked"; ! grep -q 'patch hides b' "$T/task-blocked" || { echo "negative check failed: test/ci/review-dispatch-route.sh:185" >&2; exit 1; }
test "$(cut -d' ' -f2 "$sent")" = "$B"
echo 'author unwakeable → fixer'

# 5. route=fixer → fixer only (devfix fast path), no author told
reset
F1="review-gate: FINDING #1 route=fixer commit=- — one missing check
review-gate: ROUTE fixer — one missing check
review-gate: BLOCKED #1 regression [blocker]: missing check
evidence: src/a.ts:3 x"
dev_blocked "$S" "$F1" "" run-url task
test "$(cat "$woken")" = "$S blocked"; test ! -e "$sent"
grep -q "commit ${CA:0:12}" "$T/task-blocked"   # the fixer task names whose code it is
echo 'route=fixer → fixer only'

# 6. review clean, only the trusted tests failed → fixer, despite a stray ROUTE author line
reset
dev_blocked "$S" "review-gate: ROUTE author — x
trusted tests job: failure
##[error]Code style issues found in src/a.ts. Run Prettier." "" run-url task
test "$(cat "$woken")" = "$S blocked"; test ! -e "$sent"
echo 'tests-only failure → fixer'

# 7. budget spent → it ends, regardless of route: no author routing, no fixer, NOBODY woken (owner 11-12; re-check of
#    6616b3138 #1/#2: the dev path still sent fixfailed.0 to the authors)
reset; BUDGET_OK=0; echo "3 3" > "$STATE/sent/$S.budget-spent"
dev_blocked "$S" "$F2" "" run-url task
dev_blocked "$S" "$F2" "" run-url task
test ! -e "$woken"; test ! -e "$sent"
! ls "$STATE/sent" | grep -q route-author || { echo "negative check failed: test/ci/review-dispatch-route.sh:214" >&2; exit 1; }
test "$(grep -c 'fix rounds spent — it ends here, nobody woken' "$LOG")" -eq 1
echo 'budget spent → nobody woken'

# 8. unattributable author finding (two threads touched the file, no commit, no blameable line) → fixer, no broadcast
reset
g checkout -q -B devw origin/dev; echo more >> "$SRC/src/a.ts"; g add src/a.ts; g commit -q -m "B on a" -m "Thread: $B"
S2=$(g rev-parse HEAD); g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
FU="review-gate: FINDING #1 route=author commit=- — design
review-gate: BLOCKED #1 missed-class [blocker]: a.ts is wrong as a whole
evidence: src/a.ts has the class"
test "$(attribution "$S2" "$FU")" = "1 author - -"
dev_blocked "$S2" "$FU" "" run-url task
test "$(cat "$woken")" = "$S2 blocked"; test ! -e "$sent"
# … and when that fixer fails, the supervisor hears of it, not every range author
THREAD_STATE=interrupted
dev_blocked "$S2" "$FU" "" run-url task
test "$(cut -d' ' -f2 "$sent")" = "$SUPERVISOR_THREAD"
THREAD_STATE=running
g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
echo 'unattributable → fixer / supervisor, no broadcast'

# 9. revert order: author window first, then the fixer's own hour
reset; now=$(date +%s); since=$((now - 600))
test "$(revert_after_for "$S" "$since")" -eq 3600
echo "author $now" > "$STATE/sent/$S.route-author.x"
test "$(revert_after_for "$S" "$since")" -eq $((600 + 7200))
echo "timeout $now" > "$STATE/sent/$S.route-author.x"
test "$(revert_after_for "$S" "$since")" -eq $((600 + 3600))
echo 'revert waits for author window + fixer hour'

# 10. FYI when a fixer's fix landed: logged only, never sent (t3 has no no-wake send)
reset
fyi_author "$S" "$A" "fixed by the fixer"; fyi_author "$S" "$A" "again"
test ! -e "$sent"; test "$(grep -c '^FYI' "$LOG")" -eq 1
echo 'FYI: log only'

# 11. a reverted Review-Fix-Of commit is no fix (review of d250a92a0 #1/#2)
reset
g checkout -q -B devw origin/dev; R=$(commit src/a.ts "$A" "Review-Fix-Of: $S")
g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin
dev_carries_fix "$S" ""
g revert --no-edit HEAD >/dev/null; g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin
if dev_carries_fix "$S" ""; then echo "unexpected: a reverted fix still counts on dev" >&2; exit 1; fi
H=$(g rev-parse origin/main)
g checkout -q -B mainw origin/main; R=$(commit src/h.ts "$A" "Review-Fix-Of: $H"); g push -q origin HEAD:refs/heads/main; g fetch -q origin
test "$(hotfix_fix_pushed "$H")" = "$R"
g revert --no-edit HEAD >/dev/null; g push -q origin HEAD:refs/heads/main; g fetch -q origin
if hotfix_fix_pushed "$H" >/dev/null; then echo "unexpected: a reverted hotfix re-check fix still counts" >&2; exit 1; fi
# re-check of e3aca30fd #8: a revert of the revert restores the repair; a third revert removes it again
g revert --no-edit HEAD >/dev/null; g push -q origin HEAD:refs/heads/main; g fetch -q origin
test "$(hotfix_fix_pushed "$H")" = "$R"
g revert --no-edit HEAD >/dev/null; g push -q origin HEAD:refs/heads/main; g fetch -q origin
if hotfix_fix_pushed "$H" >/dev/null; then echo "unexpected: a re-reverted repair still counts" >&2; exit 1; fi
g checkout -q main; g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
echo 'reverted fix is no fix'
# re-check of e3aca30fd #7: a thread's repair is found behind more than twenty newer repairs of other threads
reset
g checkout -q -B devw origin/dev; RA=$(commit src/a.ts "$A" "Review-Fix-Of: $S")
for i in $(seq 1 21); do commit "src/x$i.ts" "mcp:other-$i" "Review-Fix-Of: $S" >/dev/null; done
g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
test "$(repair_effective "$S" "$A" origin/dev)" = "$RA"
g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
echo 'repair lookup: thread filter over every repair'

# 12. an ended conflict fixer escalates once (landmain / train, review of d250a92a0 #3); a live one does not
reset
escalate_ended_fixer "$S" landmain-abc "$A" msg; test ! -e "$sent"          # no receipt
echo "$THREAD_ID" > "$STATE/sent/$S.fixer-landmain-abc"
escalate_ended_fixer "$S" landmain-abc "$A" msg; test ! -e "$sent"          # still running
THREAD_STATE=completed
escalate_ended_fixer "$S" landmain-abc "$A" msg
test "$(cat "$sent")" = "ended-landmain-abc.0 $A"
escalate_ended_fixer "$S" train-abc "" msg2 2>/dev/null || :; test ! -e "$STATE/sent/x"
echo "$THREAD_ID" > "$STATE/sent/$S.fixer-train-abc"; escalate_ended_fixer "$S" train-abc "" msg2
tail -1 "$sent" | grep -qx "ended-train-abc.0 $SUPERVISOR_THREAD"
grep -q 'escalate_ended_fixer "$fh" "landmain-' "$D"; grep -q 'escalate_ended_fixer "$tsha" "train-' "$D"
THREAD_STATE=running
echo 'ended conflict fixers escalate'

# 13. (main re-check findings: owner first / strongest fixer — test/ci/review-dispatch-main-owner.sh)
# 14. re-check of 32e2af473 #6: findings() keeps complete per-finding blocks, capped by findings (not 60 lines)
mklog() { # mklog old|new <n> → a review job log of n author-routed findings in src/a.ts
  local i
  if [ "$1" = old ]; then
    for i in $(seq 1 "$2"); do echo "2026-11-12T00:00:00Z review-gate: FINDING #$i route=author commit=- — r$i"; done
    echo "2026-11-12T00:00:00Z review-gate: ROUTE author — r1"
    for i in $(seq 1 "$2"); do echo "2026-11-12T00:00:00Z review-gate: BLOCKED #$i regression [should]: bug $i"; echo "2026-11-12T00:00:00Z evidence: src/a.ts:3 e$i"; done
  else
    echo "2026-11-12T00:00:00Z review-gate: ROUTE author — r1"
    for i in $(seq 1 "$2"); do echo "2026-11-12T00:00:00Z review-gate: FINDING #$i route=author commit=- — r$i"; echo "2026-11-12T00:00:00Z review-gate: BLOCKED #$i regression [should]: bug $i"; echo "2026-11-12T00:00:00Z evidence: src/a.ts:3 e$i"; done
  fi
}
eval "$(fns findings)"
for fmt in old new; do
  gh() { case "$*" in *"/jobs/"*logs*) mklog "$LOGFMT" 60 ;; *) echo '{"jobs":[{"name":"tests","conclusion":"success","id":1},{"name":"review","conclusion":"failure","id":2}]}' ;; esac; }
  LOGFMT=$fmt; out=$(FINDINGS_MAX=25 findings 1)   # an explicit cap (display only)
  test "$(finding_blocks "$out" | wc -l)" -eq 25
  test "$(grep -c '^review-gate: FINDING #' <<<"$out")" -eq 25
  test "$(attribution "$S" "$out" | awk '$2 == "author" && $4 != "-"' | wc -l)" -eq 25
  grep -q '35 more findings not listed' <<<"$out"
done
# re-check of f0d573631 #7: by default nothing is dropped — the 60th finding's route=author still decides the round
mklog2() { echo "2026-11-12T00:00:00Z review-gate: ROUTE fixer — r"; for i in $(seq 1 60); do r=fixer; [ "$i" = 60 ] && r=author
  echo "2026-11-12T00:00:00Z review-gate: FINDING #$i route=$r commit=- — r$i"; echo "2026-11-12T00:00:00Z review-gate: BLOCKED #$i regression [should]: bug $i"; echo "2026-11-12T00:00:00Z evidence: src/a.ts:3 e$i"; done; }
gh() { case "$*" in *"/jobs/"*logs*) mklog2 ;; *) echo '{"jobs":[{"name":"tests","conclusion":"success","id":1},{"name":"review","conclusion":"failure","id":2}]}' ;; esac; }
out=$(findings 1)
test "$(finding_blocks "$out" | wc -l)" -eq 60; ! grep -q 'more findings not listed' <<<"$out" || { echo "negative check failed: test/ci/review-dispatch-route.sh:363" >&2; exit 1; }
test "$(review_round_route "$out")" = author
gh() { printf '%s\n' "${PENDING:-}"; }
echo 'findings(): complete blocks, capped by finding'
echo 'route checks passed'

# 11-12: the CI owner's thread (DISPATCH_THREAD) and the supervisor's are real authors — an author route reaches them
reset
author_turn "$S" "$DISPATCH_THREAD" "$F2" "msg" origin/dev
grep -q "$DISPATCH_THREAD" "$sent"; ! grep -q 'not wakeable' "$LOG" || { echo "negative check failed: test/ci/review-dispatch-route.sh:372" >&2; exit 1; }
reset
author_turn "$S" "$SUPERVISOR_THREAD" "$F2" "msg" origin/dev
grep -q "$SUPERVISOR_THREAD" "$sent"; ! grep -q 'not wakeable' "$LOG" || { echo "negative check failed: test/ci/review-dispatch-route.sh:375" >&2; exit 1; }
reset
rc=0; author_turn "$S" "" "$F2" "msg" origin/dev || rc=$?; test "$rc" = 1   # no Thread: at all → fixer
echo 'author route reaches the CI owner and the supervisor'

# re-check of b06fcbb80 #1: a repair the reviewed head already CONTAINS fixed nothing — its fresh findings are handled
reset
g checkout -q -B devw "$S"; commit src/a.ts "$A" "Review-Fix-Of: $CA" >/dev/null; commit src/b.ts "$B" "Review-Fix-Of: $CB" >/dev/null
S2=$(g rev-parse HEAD); g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
dev_blocked "$S2" "$F2" "" run-url task
! grep -q 'already repairs its culprit commit' "$LOG" || { echo "negative check failed: test/ci/review-dispatch-route.sh:385" >&2; exit 1; }
g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
# re-check of b06fcbb80 #2: one repair commit with two Review-Fix-Of trailers repairs both
g checkout -q -B devw origin/dev; R2=$(commit src/a.ts "$A" "Review-Fix-Of: $CA
Review-Fix-Of: $CB"); g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
test "$(repair_effective "$CA" "" origin/dev)" = "$R2"; test "$(repair_effective "$CB" "" origin/dev)" = "$R2"
g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
echo 'repairs already in the reviewed head do not count; every Review-Fix-Of trailer counts'

# re-check of 0b463b6c0 #8: a long revert chain is followed, not cut at 6 (7 reverts → absent, 8 → present again)
reset
g checkout -q -B mainw origin/main; H=$(g rev-parse HEAD); R=$(commit src/chain.ts "$A" "Review-Fix-Of: $H")
for i in $(seq 1 7); do g revert --no-edit HEAD >/dev/null; done
g push -q origin HEAD:refs/heads/main; g fetch -q origin
if repair_effective "$H" "" origin/main >/dev/null; then echo "unexpected: a 7-times reverted repair counts" >&2; exit 1; fi
g revert --no-edit HEAD >/dev/null; g push -q origin HEAD:refs/heads/main; g fetch -q origin
test "$(repair_effective "$H" "" origin/main)" = "$R"
g checkout -q main
echo 'revert chains: followed to the end'

# re-check of 8abff5c3c #3: a stale "fallback no author thread" marker (written before the owner/supervisor fix) is ignored
reset
echo "fallback no author thread" > "$STATE/sent/$S.route-author.${DISPATCH_THREAD//[^A-Za-z0-9-]/_}"
author_turn "$S" "$DISPATCH_THREAD" "$F2" "msg" origin/dev
grep -q "$DISPATCH_THREAD" "$sent"
echo 'stale no-author marker: decided again'

# (owner 11-13: no round budget on main — test/ci/review-dispatch-main-owner.sh)
# review of 1dd12b37b #7: a repair on main that dev has reverted still counts — each ref is judged on its own
reset
g checkout -q -B mainw origin/main; H=$(g rev-parse HEAD); R=$(commit src/perref.ts "$A" "Review-Fix-Of: $H")
g push -q origin HEAD:refs/heads/main; g fetch -q origin
g checkout -q -B devw origin/main; g revert --no-edit "$R" >/dev/null; g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
test "$(repair_effective "$H" "" origin/main origin/dev)" = "$R"     # stands on main
if repair_effective "$H" "" origin/dev >/dev/null; then echo "unexpected: reverted on dev yet counted for dev alone" >&2; exit 1; fi
g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
echo 'repair judged per ref'

# tralyx 26b73ac1b (11-14): #1-#3 route=author on de62c187b (repaired on dev by 124cfe5a3), #4 route=fixer on 26b73ac1b itself
# (unrepaired) → #1-#3 dropped (the author is not told again), the fixer gets #4 only. 33b2b479b had the same shape (#1/#2 on
# de62c187b, #3 on 180715225).
F4="review-gate: FINDING #1 route=author commit=$CA — payment attribution
review-gate: BLOCKED #1 ducktape [should]: singleton valuation one
evidence: src/a.ts:1 one
review-gate: FINDING #2 route=author commit=$CA — payment attribution two
review-gate: BLOCKED #2 ducktape [should]: singleton valuation two
evidence: src/a.ts:2 two
review-gate: FINDING #3 route=author commit=$CA — batched swaps
review-gate: BLOCKED #3 regression [should]: batched settlement three
evidence: src/a.ts:3 three
review-gate: FINDING #4 route=fixer commit=$CB — retired task keys
review-gate: BLOCKED #4 regression [should]: retired keys stay in the failure set
evidence: src/b.ts:4 four"
reset
g checkout -q -B devw "$S"; RA4=$(commit src/a.ts "$A" "Review-Fix-Of: $CA")
g push -q -f origin HEAD:refs/heads/dev; g fetch -q origin; g checkout -q main
# a production-shaped task (dev scan): every finding + the devfix reset — none of it may reach the fixer of the rest
dev_blocked "$S" "$F4" "" run-url "Task: the blocking review stopped dev at ${S:0:9}. Findings:
$F4
Your worktree starts at origin/dev; first git reset --hard ${S} so the fix sits directly on the reviewed commit."
grep -q "dropped finding(s) 1 2 3 — dev already repairs their culprit commit(s) (#1: ${RA4:0:9} repairs ${CA:0:9}; #2: ${RA4:0:9} repairs ${CA:0:9}; #3: ${RA4:0:9} repairs ${CA:0:9};); routing only 4" "$LOG"
test ! -e "$T/msg-${A##*:}"; test "$(cat "$woken")" = "$S rest"
grep -q 'retired keys stay' "$T/task-rest"; grep -q "^#4 → commit ${CB:0:12}" "$T/task-rest"; grep -q 'stay there (do NOT reset' "$T/task-rest"
! grep -qE 'singleton valuation|batched settlement|^#[123] →|git reset --hard' "$T/task-rest" || { echo "negative check failed: the fixer got repaired findings or the devfix reset" >&2; exit 1; }
g push -q -f origin "$S:refs/heads/dev"; g fetch -q origin
echo 'tralyx 26b73ac1b shape: repaired findings dropped, the unrepaired one routed alone'
