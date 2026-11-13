#!/usr/bin/env bash
# One main reviewer at a time (owner 11-12): H2's reviewer was cancelled while waiting, so the re-check of H3 reviewed
# H1..H3 (H2 + H3) in one range. The dispatcher's hotfix loop must treat H2 as covered by that run (no fixer, no notice
# of its own), and handle H3's block with per-finding attribution over the whole batch (owner 11-13): each finding goes to
# the owner of its culprit commit — each author hears only their own findings — and an unreachable owner's go to the
# strongest fixer, whose task names the culprit commit.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
# Any command that is not found — a dispatcher helper the test did not extract — fails the whole test at once, even
# inside an if / || condition (review of 02828988f #7: "culprits_repaired: command not found" printed, test exited 0).
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fns() { local n; for n in "$@"; do sed -n "/^$n() {/,/^}/p; /^$n() { .*}\$/p" "$D"; done; }
eval "$(fns findings findings_cap thread_of fixer_receipt_thread norm_tid finding_blocks finding_meta finding_route review_round_route route_reason \
  attribute_finding attribution findings_subset att_of culprit_lines named_files repair_effective fix_reverted hotfix_fix_pushed \
  author_turn author_fixed fyi_author or_supervisor fix_of)"
eval "$(fns review_list)"   # the trusted-run filter (review-runs.sh rule) over the fake run list
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
b = s.index('\ndone\n', a) + 6
print(s[a:b])
PY
)
eval "$helpers"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DEV=dev REPO=test/repo AUTHOR_FIX_WINDOW_SEC=3600 FIXER_GATE=$T/state/fixer-gate
SUPERVISOR_THREAD=import:claudeAgent:sup key_prefix=""
mkdir -p "$STATE/sent" "$FIXER_GATE/queue"
LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
A=mcp:11111111-1111-1111-1111-111111111111 B=mcp:22222222-2222-2222-2222-222222222222 C=mcp:33333333-3333-3333-3333-333333333333
git init -q --bare "$T/remote.git"; git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
commit() { mkdir -p "$SRC/$(dirname "$1")"; printf '%s\n' "$RANDOM" "$RANDOM" "$RANDOM" > "$SRC/$1"; g add "$1"
  g commit -q -m "hotfix $1" -m "Hotfix: $1
Thread: $2"; g rev-parse HEAD; }
X=$(g commit -q --allow-empty -m base && g rev-parse HEAD)
H1=$(commit src/a.ts "$A"); H2=$(commit src/b.ts "$B"); H3=$(commit src/c.ts "$C")
g push -q origin HEAD:refs/heads/main; g fetch -q origin
# runs: H1 reviewed alone (passed), H2's reviewer cancelled while waiting, H3's reviewer reviewed H1..H3 and blocked
cat > "$T/runs.json" <<J
[{"event":"workflow_run","headBranch":"main","databaseId":3,"displayTitle":"recheck $H3","status":"completed"},{"event":"workflow_run","headBranch":"main","databaseId":2,"displayTitle":"recheck $H2","status":"completed"},
 {"event":"workflow_run","headBranch":"main","databaseId":1,"displayTitle":"recheck $H1","status":"completed"}]
J
cat > "$T/log3" <<L
2026-11-12T00:00:00Z review-range: $H1 $H3
2026-11-12T00:00:00Z review-gate: FINDING #1 route=fixer commit=- — mechanical
2026-11-12T00:00:00Z review-gate: FINDING #2 route=fixer commit=- — mechanical
2026-11-12T00:00:00Z review-gate: BLOCKED #1 regression [blocker]: b drops the row
2026-11-12T00:00:00Z evidence: src/b.ts:2 drops it
2026-11-12T00:00:00Z review-gate: BLOCKED #2 ducktape [should]: c hides the error
2026-11-12T00:00:00Z evidence: src/c.ts:1 swallows it
L
gh() { # honours -q <jq> like the real gh
  local q="" a; for a in "$@"; do if [ "$q" = next ]; then q=$a; break; fi; if [ "$a" = -q ]; then q=next; fi; done
  if [ -n "$q" ] && [ "$q" != next ]; then gh_raw "$@" | jq -r "$q"; else gh_raw "$@"; fi
}
gh_raw() {
  case "$*" in
    "run list"*) cat "$T/runs.json" ;;
    *runs/1/jobs*) echo '{"jobs":[{"name":"tests","id":10,"conclusion":"success"},{"name":"review","id":11,"conclusion":"success","steps":[{"name":"Review (blocking; x)","conclusion":"success"}]}]}' ;;
    *runs/2/jobs*) echo '{"jobs":[{"name":"tests","id":20,"conclusion":"success"},{"name":"review","id":21,"conclusion":"cancelled","steps":[]}]}' ;;
    *runs/3/jobs*) echo '{"jobs":[{"name":"tests","id":30,"conclusion":"success"},{"name":"review","id":31,"conclusion":"failure","steps":[{"name":"Review (blocking; x)","conclusion":"failure"}]}]}' ;;
    *jobs/31/logs*) cat "$T/log3" ;;
    *jobs/*/logs*) : ;;
    *"runs/1 "*|*"runs/1") echo '{"conclusion":"success"}' ;;
    *"runs/2 "*|*"runs/2") echo '{"conclusion":"cancelled"}' ;;
    *"runs/3 "*|*"runs/3") echo '{"conclusion":"failure"}' ;;
    *) echo '{}' ;;
  esac
}
woken=$T/woken
wake_fixer() { [ -e "$STATE/sent/$1.fixer-$2" ] && return 0; echo "$1 $2" >> "$woken"; printf '%s\n' "$4" > "$T/task-${1:0:9}"; echo fixer-thread > "$STATE/sent/$1.fixer-$2"; }
UNREACHABLE=""
notify() { echo "$2 $3" >> "$T/sent"; printf '%s\n' "$4" > "$T/msg-${3##*:}"
  if [ "$3" = "$UNREACHABLE" ]; then notify_outcome=skipped; else notify_outcome=sent; fi; echo "$notify_outcome" > "$STATE/sent/$1.$2"; }
notify_best_effort() { notify "$@" || :; }
FIXER_DONE=""; fixer_ended() { if [ -n "$FIXER_DONE" ] && [ -e "$1" ]; then echo "fixer ended"; return 0; fi; return 1; }

# 1. one dispatch run: H1 passed, H2 covered by H3's batched run, H3 → each culprit's owner gets only their own finding
eval "$loop"
test -e "$STATE/sent/$H1.hotfix-complete"
test -e "$STATE/sent/$H2.hotfix-complete"; grep -q "HOTFIX ${H2:0:9}: its reviewer was superseded; covered by the batched re-check of ${H3:0:9}" "$LOG"
test "$(cut -d' ' -f2 "$T/sent" | sort | tr '\n' ' ')" = "$B $C "        # nobody for H1's author
grep -q 'b drops the row' "$T/msg-${B##*:}"; ! grep -q 'c hides the error' "$T/msg-${B##*:}" || { echo "negative check failed: B got C's finding" >&2; exit 1; }
grep -q 'c hides the error' "$T/msg-${C##*:}"; ! grep -q 'b drops the row' "$T/msg-${C##*:}" || { echo "negative check failed: C got B's finding" >&2; exit 1; }
test ! -e "$woken"; test ! -e "$STATE/sent/$H3.hotfix-complete"
n=$(wc -l < "$T/sent"); eval "$loop"; test "$(wc -l < "$T/sent")" = "$n"   # later runs within 30 min: nothing new
echo 'batched re-check: the covered head is not re-handled; each owner only their own finding'

# 2. an unreachable owner → the strongest fixer for that owner's finding only; its task names the culprit commit
rm -rf "$STATE/sent" "$T/sent"; mkdir -p "$STATE/sent"; UNREACHABLE=$B
eval "$loop"
test "$(cut -d' ' -f2 "$woken")" = "$(grep -o 'mainfix-[0-9a-f]*' "$woken")"
grep -q "#1 → commit ${H2:0:12}" "$T/task-${H3:0:9}"; ! grep -q '#2 → commit' "$T/task-${H3:0:9}" || { echo "negative check failed: the fixer got C's finding" >&2; exit 1; }
grep -q 'b drops the row' "$T/task-${H3:0:9}"
echo 'batched re-check: unreachable owner → strongest fixer for their finding'
UNREACHABLE=""

# 3. a cancelled reviewer whose covering run has not completed yet waits (not completed, not handled)
rm -rf "$STATE/sent"; mkdir -p "$STATE/sent"; rm -f "$woken" "$T/sent"; FIXER_DONE=""
printf '[{"event":"workflow_run","headBranch":"main","databaseId":2,"displayTitle":"recheck %s","status":"completed"},{"event":"workflow_run","headBranch":"main","databaseId":3,"displayTitle":"recheck %s","status":"in_progress"}]\n' "$H2" "$H3" > "$T/runs.json"
hotfix_runs=""
eval "$loop"
test ! -e "$STATE/sent/$H2.hotfix-complete"; test ! -e "$woken"
echo 'batched re-check: a covered head waits for the covering review'
echo 'batched re-check checks passed'
