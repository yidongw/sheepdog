#!/usr/bin/env bash
# One fixer per repo at a time (owner 11-12): wake_fixer queues a request while another fixer of the repo is
# live, keeps the once-per-sha+key receipt unconsumed, prefers main-side fixes, releases ended/stale holders
# and drops queued requests nobody makes any more.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
# Any command that is not found — a dispatcher helper the test did not extract — fails the whole test at once, even
# inside an if / || condition (review of 02828988f #7: "culprits_repaired: command not found" printed, test exited 0).
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
script=$PWD/scripts/ci/review-dispatch.sh
STATE=$(mktemp -d)
trap 'rm -rf "$STATE"' EXIT
mkdir -p "$STATE/sent"
LOG=$STATE/dispatch.log
log() { echo "$*" >> "$LOG"; }
DEV=dev T3_PROJECT=test-project REVIEW_NOTIFY_HELPER=$PWD/scripts/ci/review-notify.sh
eval "$(sed -n '/^FIXER_GATE_STALE_MIN=/,/^wake_fixer() {/{ /^wake_fixer() {/d; p; }' "$script")"
eval "$(sed -n '/^wake_fixer() {/,/^}/p' "$script")"; for _f in wake_fixer; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
timeout() { shift; "$@"; }
# the fake T3 keeps its state in files: wake_fixer runs `t3 thread start` inside $(…)
T3D=$STATE/t3; mkdir -p "$T3D/threads"; echo 0 > "$T3D/started"
set_status() { if [ -n "$2" ]; then echo "$2" > "$T3D/threads/${1//:/_}"; else rm -f "$T3D/threads/${1//:/_}"; fi; }
started() { cat "$T3D/started"; }
t3() {
  case "$2" in
    show) if [ -e "$T3D/threads/${3//:/_}" ]; then [ "$(cat "$T3D/threads/${3//:/_}")" = UNKNOWN ] && return 0; printf '%s  %s  codex\n' "$3" "$(cat "$T3D/threads/${3//:/_}")"
          else echo "Thread $3 is no longer available."; return 1; fi ;;
    start) cat >/dev/null; local n; n=$(( $(started) + 1 )); echo "$n" > "$T3D/started"
           local tid; tid=$(printf 'mcp:%08d-0000-0000-0000-000000000000' "$n"); set_status "$tid" running
           echo "started $tid" ;;
  esac
}
fresh_run() { fixer_gate_holder=""; fixer_gate_scanned=""; }
sha() { printf '%040d' "$1" | tr 0 "$2"; }
A=$(sha 0 a); B=$(sha 0 b); C=$(sha 0 c); D=$(sha 0 d)

# 1. gate free → the first request wakes a fixer and holds the gate
fresh_run
wake_fixer "$A" blocked t task
test "$(started)" = 1
tidA=$(head -1 "$STATE/sent/$A.fixer-blocked")
# 2. same run, another request → queued, no receipt, non-zero, logged once
if wake_fixer "$B" recheck t task; then echo "unexpected: second fixer woken while one is live" >&2; exit 1; fi
test "$(started)" = 1
test ! -e "$STATE/sent/$B.fixer-recheck"
test -e "$STATE/fixer-gate/queue/$B.recheck"
fresh_run
if wake_fixer "$B" recheck t task; then echo "unexpected: woken while the holder is still running" >&2; exit 1; fi
test "$(grep -c "queued recheck ${B:0:9}" "$LOG")" = 1
# 3. a lower-priority request also queues
if wake_fixer "$C" blocked t task; then echo "unexpected" >&2; exit 1; fi
# 4. the holder ends → gate released (logged); the blocked request yields to the queued recheck
set_status "$tidA" interrupted
fresh_run
if wake_fixer "$C" blocked t task; then echo "unexpected: blocked jumped ahead of a queued recheck" >&2; exit 1; fi
grep -q "fixer gate: blocked ${A:0:9} ($tidA) is interrupted — gate released" "$LOG"
test -e "$STATE/fixer-gate/queue/$C.blocked"   # still queued (logged once, at step 3)
test "$(started)" = 1
wake_fixer "$B" recheck t task             # later in the same run: the recheck goes
test "$(started)" = 2
test ! -e "$STATE/fixer-gate/queue/$B.recheck"
if wake_fixer "$C" blocked t task; then echo "unexpected: second fixer in the same run" >&2; exit 1; fi
# 5. a receipt never re-wakes (once per sha+key), even with the gate busy
wake_fixer "$B" recheck t task
test "$(started)" = 2
# 6. a running holder remains exclusive regardless of receipt age
touch -d '-100 minutes' "$STATE/sent/$B.fixer-recheck"
fresh_run
if wake_fixer "$C" blocked t task; then echo "released running holder" >&2; exit 1; fi
test "$(started)" = 2
set_status "$(head -1 "$STATE/sent/$B.fixer-recheck")" completed
fresh_run
wake_fixer "$C" blocked t task
test "$(started)" = 3
# 7. a gone thread releases the gate; a queued request not repeated within the TTL is dropped (target moot)
tidC=$(head -1 "$STATE/sent/$C.fixer-blocked"); set_status "$tidC" ""
fresh_run
if DRY=1 wake_fixer "$D" testsfail t task >/dev/null; then :; fi   # DRY: no state written
echo 4 > "$STATE/fixer-gate/queue/$D.blocked"; touch -d '-20 minutes' "$STATE/fixer-gate/queue/$D.blocked"
wake_fixer "$D" testsfail t task
test "$(started)" = 4
grep -q "fixer queue: dropped blocked ${D:0:9} — not requested for 10 min (target moot)" "$LOG"
test ! -e "$STATE/fixer-gate/queue/$D.blocked"
# 8. DRY never writes queue entries
fresh_run
out=$(DRY=1 wake_fixer "$A" "mainmerge-$(printf '%09d' 1)" t task || true)
grep -q 'DRY fixer busy' <<<"$out"
test ! -e "$STATE/fixer-gate/queue/$A.mainmerge-000000001"
# 9. gate free, a queued main-side fix is still wanted → a new lower-priority request yields (logged once)
set_status "$(head -1 "$STATE/sent/$D.fixer-testsfail")" completed
echo 1 > "$STATE/fixer-gate/queue/$A.hotfixfix"
fresh_run
if wake_fixer "$C" "train-$(printf '%09d' 2)" t task; then echo "unexpected: train jumped ahead of a queued hotfixfix" >&2; exit 1; fi
grep -q "fixer slot kept for higher-priority hotfixfix ${A:0:9}: queued train-000000002 ${C:0:9}" "$LOG"
test "$(started)" = 4
# 10. an EMPTY receipt (a marker: merge-only-round cancel, old receipt) newer than a finished fixer never holds the gate
rm -f "$STATE/fixer-gate/queue/"*
E=$(sha 0 e); F=$(sha 0 f)
: > "$STATE/sent/$E.fixer-blocked"       # newest receipt, no thread id
fresh_run
wake_fixer "$F" hotfixfix t task
test "$(started)" = 5
test -e "$STATE/fixer-gate/ended/$E.fixer-blocked"
# … and an unknown T3 state of a real tid holds only within FIXER_GATE_STALE_MIN
set_status "$(head -1 "$STATE/sent/$F.fixer-hotfixfix")" completed
G=$(sha 0 1); tidG=mcp:99999999-0000-0000-0000-000000000000
echo "$tidG" > "$STATE/sent/$G.fixer-blocked"; set_status "$tidG" UNKNOWN   # t3 prints no state for it
fresh_run
if wake_fixer "$(sha 0 2)" blocked t task; then echo "unexpected: an unknown-state fresh receipt released the gate" >&2; exit 1; fi
touch -d '-100 minutes' "$STATE/sent/$G.fixer-blocked"; rm -f "$STATE/fixer-gate/queue/"*
fresh_run
wake_fixer "$(sha 0 2)" blocked t task
test "$(started)" = 6
echo 'empty receipts never hold the gate; unknown state holds only while fresh'
echo 'fixer gate checks passed'
