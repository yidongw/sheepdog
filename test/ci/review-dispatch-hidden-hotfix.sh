#!/usr/bin/env bash
# The dev train fast-forwards main to "merge main (<hotfix>) into dev" — a merge whose FIRST parent is dev. A hotfix that was
# blocked on main then sits on a SECOND parent (11-13: dc5e2b504, 716197fce). The hotfix loop must still see it: once the
# strongest fixer's repair is on main, the hotfix is completed and its owner gets the digest — with a --first-parent walk it
# was never visited again (never completed, no digest, no escalation). Completed ones are not re-processed, and the first
# run does not reach below the walk base (no old backlog).
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
OLD=$(commit src/old.ts "Hotfix: an old hotfix nobody completed
Thread: $A")
for i in $(seq 1 22); do commit "src/n$i.ts" "plain $i" >/dev/null; done
X=$(g rev-parse HEAD)
g push -q origin HEAD:refs/heads/main HEAD:refs/heads/dev; g fetch -q origin
H=$(commit src/h.ts "Hotfix: h
Thread: $A"); g push -q origin HEAD:refs/heads/main; g fetch -q origin
cat > "$T/runs.json" <<J
[{"databaseId":5,"displayTitle":"recheck $H","status":"completed"},{"databaseId":4,"displayTitle":"recheck $OLD","status":"completed"}]
J
gh() { local q="" a; for a in "$@"; do if [ "$q" = next ]; then q=$a; break; fi; if [ "$a" = -q ]; then q=next; fi; done
  if [ -n "$q" ] && [ "$q" != next ]; then gh_raw "$@" | jq -r "$q"; else gh_raw "$@"; fi; }
gh_raw() { case "$*" in
  "run list"*) cat "$T/runs.json" ;;
  *runs/[45]/jobs*) echo '{"jobs":[{"name":"tests","id":50,"conclusion":"success"},{"name":"review","id":51,"conclusion":"failure","steps":[{"name":"Review (blocking; x)","conclusion":"failure"}]}]}' ;;
  *jobs/51/logs*) printf '2026-11-13T00:00:00Z review-range: %s %s\n2026-11-13T00:00:00Z review-gate: FINDING #1 route=fixer commit=- — x\n2026-11-13T00:00:00Z review-gate: BLOCKED #1 regression [should]: h drops rows\n2026-11-13T00:00:00Z evidence: src/h.ts:1 x\n' "$X" "$H" ;;
  *"runs/5"*|*"runs/4"*) echo '{"conclusion":"failure"}' ;;
  *) echo '{}' ;; esac; }
notify() { if [ -e "$STATE/sent/$1.$2" ]; then notify_outcome=dup; [ "$(head -1 "$STATE/sent/$1.$2")" = skipped ] && notify_outcome=skipped; return 0; fi
  echo "$2 $3" >> "$T/sent"; notify_outcome=skipped; echo skipped > "$STATE/sent/$1.$2"; }   # the owner is unreachable → the fixer
notify_best_effort() { notify "$@" || :; }
wake_fixer() { [ -e "$STATE/sent/$1.fixer-$2" ] && return 0; echo "$1 $2" >> "$T/woken"; echo "$FX" > "$STATE/sent/$1.fixer-$2"; }
fixer_ended() { return 1; }

# 1. H blocked on main's first-parent line → the strongest fixer (owner unreachable); OLD (below the walk base) untouched
eval "$loop"
grep -q "^$H mainfix-" "$T/woken" || fail "H not handled while on the first-parent line"
if grep -q "^$OLD" "$T/woken" "$T/sent" 2>/dev/null; then fail "the first run reached an old hotfix below the walk base"; fi

# 2. the fixer repairs H on main; dev merges main; the train fast-forwards main to that merge (first parent = dev)
R=$(commit src/h.ts "Hotfix: fix h
Review-Fix-Of: $H
Fixes-Finding: #1 h drops rows
Loop: dev-fixer
Thread: $FX"); g push -q origin HEAD:refs/heads/main
g checkout -q -B devw "$X"; commit src/dev.ts "dev work" >/dev/null
g merge -q --no-ff -m "merge main (${R:0:9}) into dev" -m "Loop: review-dispatch" "$R"; M=$(g rev-parse HEAD)
g push -q -f origin HEAD:refs/heads/dev HEAD:refs/heads/main; g fetch -q origin; g checkout -q main
if git -C "$SRC" rev-list --first-parent origin/main | grep -qx "$H"; then fail "setup: H still on the first-parent line"; fi
eval "$loop"
test -e "$STATE/sent/$H.hotfix-complete" || fail "a hotfix behind a train merge's second parent is never completed"
grep -q "^${R:0:9} main ${H:0:9} #1 regression \[should\]: h drops rows" "$(digest_file "$A")" || fail "no owner digest for the hidden hotfix"
echo 'hotfix behind a train merge: completed, owner digest'

# 3. completed ones are not re-processed
n=$(wc -l < "$LOG"); eval "$loop"
if tail -n +"$((n + 1))" "$LOG" | grep -q "${H:0:9}"; then fail "a completed hotfix was processed again"; fi
if grep -q "^$OLD" "$T/woken" "$T/sent" 2>/dev/null; then fail "an old hotfix below the walk base was reached"; fi
test -s "$STATE/main-walk-base" || fail "no walk base recorded"
echo 'hidden hotfix checks passed'
