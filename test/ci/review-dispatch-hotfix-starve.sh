#!/usr/bin/env bash
# Re-check of 9cd9978ad #1: the candidate cap must not starve a blocked main hotfix H behind newer side-branch Hotfix:
# commits that never get a review run of their own (they reached main inside a merge). The cap counts only commits with a
# run; a run-less commit leaves the set once a completed main review covered it; an H about to leave the 7-day window is
# escalated (supervisor, once) instead of vanishing.
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
source scripts/ci/review-notify.sh   # digest_add / digest_file
eval "$(fns findings findings_cap thread_of fixer_receipt_thread norm_tid finding_blocks finding_meta finding_route attribute_finding attribution findings_subset \
  att_of named_files repair_effective fix_reverted fix_of launch_failed)"
eval "$(fns review_list)"   # the trusted-run filter (review-runs.sh rule) over the fake run list
sect() { python3 - "$D" "$1" "$2" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index(sys.argv[2]); b = s.index(sys.argv[3], a)
print(s[a:b + (6 if sys.argv[3] == '\ndone\n' else 0)])
PY
}
eval "$(sect '# ── main re-checks, batched' '# ── hotfix commits on main')"
loop=$(sect '# ── hotfix commits on main' $'\ndone\n')
A=mcp:11111111-1111-1111-1111-111111111111 FX=mcp:99999999-9999-9999-9999-999999999999
git init -q --bare "$T/remote.git"; git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
commit() { mkdir -p "$SRC/$(dirname "$1")"; printf '%s\n' "$RANDOM$RANDOM" >> "$SRC/$1"; g add "$1"; g commit -q -m "change $1" -m "$2"; g rev-parse HEAD; }
export GIT_COMMITTER_DATE GIT_AUTHOR_DATE; GIT_COMMITTER_DATE=$(date -d "-3 hours" -R); GIT_AUTHOR_DATE=$GIT_COMMITTER_DATE
for i in $(seq 1 22); do commit "src/n$i.ts" "plain $i" >/dev/null; done
X=$(g rev-parse HEAD)
g push -q origin HEAD:refs/heads/main HEAD:refs/heads/dev; g fetch -q origin
GIT_COMMITTER_DATE=$(date -d "-2 hours" -R); GIT_AUTHOR_DATE=$GIT_COMMITTER_DATE   # H is older than the side commits
H=$(commit src/h.ts "Hotfix: h
Thread: $A"); g push -q origin HEAD:refs/heads/main; g fetch -q origin
unset GIT_COMMITTER_DATE GIT_AUTHOR_DATE
# 41 newer Hotfix: commits on a side branch, landed by one merge — none has a review run of its own
g checkout -q -b side "$H"
for i in $(seq 1 41); do commit "src/s$i.ts" "Hotfix: side $i
Loop: dev-fixer
Thread: $FX" >/dev/null; done
SIDE1=$(g rev-list --reverse "$H..side" | sed -n 1p)
g checkout -q main; g merge -q --no-ff -m "train: land side" -m "Loop: review-dispatch" side; g push -q origin HEAD:refs/heads/main; g fetch -q origin
cat > "$T/runs.json" <<J
[{"event":"workflow_run","headBranch":"main","databaseId":5,"displayTitle":"recheck $H","status":"completed"}]
J
gh() { local q="" a; for a in "$@"; do if [ "$q" = next ]; then q=$a; break; fi; if [ "$a" = -q ]; then q=next; fi; done
  if [ -n "$q" ] && [ "$q" != next ]; then gh_raw "$@" | jq -r "$q"; else gh_raw "$@"; fi; }
gh_raw() { case "$*" in
  "run list"*) cat "$T/runs.json" ;;
  *runs/5/jobs*) echo '{"jobs":[{"name":"tests","id":50,"conclusion":"success"},{"name":"review","id":51,"conclusion":"failure","steps":[{"name":"Review (blocking; x)","conclusion":"failure"}]}]}' ;;
  *runs/6/jobs*) echo '{"jobs":[{"name":"tests","id":60,"conclusion":"success"},{"name":"review","id":61,"conclusion":"success","steps":[{"name":"Review (blocking; x)","conclusion":"success"}]}]}' ;;
  *jobs/51/logs*) printf '2026-11-13T00:00:00Z review-range: %s %s\n2026-11-13T00:00:00Z review-gate: FINDING #1 route=fixer commit=- — x\n2026-11-13T00:00:00Z review-gate: BLOCKED #1 regression [should]: h drops rows\n2026-11-13T00:00:00Z evidence: src/h.ts:1 x\n' "$X" "$H" ;;
  *jobs/61/logs*) printf '2026-11-13T00:00:00Z review-range: %s %s\n' "$X" "${M2:-}" ;;
  *"runs/5"*) echo '{"conclusion":"failure"}' ;;
  *"runs/6"*) echo '{"conclusion":"success"}' ;;
  *) echo '{}' ;; esac; }
notify() { if [ -e "$STATE/sent/$1.$2" ]; then notify_outcome=dup; return 0; fi
  echo "$2 $3" >> "$T/sent"; notify_outcome=sent; echo sent > "$STATE/sent/$1.$2"; }
notify_best_effort() { notify "$@" || :; }
wake_fixer() { [ -e "$STATE/sent/$1.fixer-$2" ] && return 0; echo "$1 $2" >> "$T/woken"; echo "$FX" > "$STATE/sent/$1.fixer-$2"; }
fixer_ended() { return 1; }

# 1. H (blocked, with its own run) is handled although 41 newer run-less Hotfix: commits come first
eval "$loop"
grep -q "^mainowner\.${A//[^A-Za-z0-9-]/_} $A$" "$T/sent" 2>/dev/null || fail "H was starved behind run-less side commits (never selected)"
echo 'cap counts only commits with a run: H not starved'

# 2. a completed main review that covered the run-less side commits takes them out of the set
M2=$(commit src/m2.ts "Hotfix: m2
Thread: $A"); g push -q origin HEAD:refs/heads/main; g fetch -q origin
printf '[{"event":"workflow_run","headBranch":"main","databaseId":6,"displayTitle":"recheck %s","status":"completed"},{"event":"workflow_run","headBranch":"main","databaseId":5,"displayTitle":"recheck %s","status":"completed"}]\n' "$M2" "$H" > "$T/runs.json"
hotfix_runs=""
eval "$loop"
test -e "$STATE/sent/$SIDE1.hotfix-complete" || fail "a run-less side commit covered by a completed main review stays a candidate"
grep -q "HOTFIX ${SIDE1:0:9}: no review run of its own; covered by the main re-check of ${M2:0:9}" "$LOG"
test ! -e "$STATE/sent/$H.hotfix-complete"   # H's own findings are still open
echo 'run-less commits covered by a completed review leave the set'

# 3. an incomplete hotfix about to leave the 7-day window → the supervisor is told, once
E=$(GIT_COMMITTER_DATE="$(date -d '-150 hours' -R)" commit src/e.ts "Hotfix: e
Thread: $A"); g push -q origin HEAD:refs/heads/main; g fetch -q origin
echo "$E $(date -d '-150 hours' +%s)" >> "$STATE/main-arrivals"   # the window and the age count from arrival on main
eval "$loop"; eval "$loop"
test "$(grep -c "^hotfix-expiring $SUPERVISOR_THREAD$" "$T/sent")" = 1 || fail "an expiring open hotfix was not escalated exactly once: $(grep expiring "$T/sent" || true)"
grep -q "HOTFIX ${E:0:9}: still open after" "$LOG"
echo 'hotfix starvation checks passed'
