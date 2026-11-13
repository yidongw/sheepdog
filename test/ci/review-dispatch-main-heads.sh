#!/usr/bin/env bash
# Review contract (11-13): main re-checks a head carrying Review-Fix-Of: (a tests-only dev fix that landed on its tests) or
# Train-Merge: too, titled "recheck <sha>". The dispatcher's main loop must handle such a head like a hotfix: a blocked
# re-check → owner / strongest fixer, a passed one → completed. A head whose review job was skipped (a train merge from
# before the contract) is marked done without notices; heads committed before the rule's first run are not dug up; a
# hotfix whose reviewer was superseded is covered by a Review-Fix-Of: head's completed batched re-check.
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
commit src/root.ts "root" >/dev/null
OLDFIX=$(GIT_COMMITTER_DATE="$(date -d '-2 hours' -R)" commit src/oldfix.ts "Review-Fix-Of: $(printf 'a%.0s' $(seq 40))
Thread: $A")
X=$(commit src/x.ts "plain")
g push -q origin HEAD:refs/heads/main HEAD:refs/heads/dev; g fetch -q origin
g rev-parse "$OLDFIX^" > "$STATE/main-walk-base"   # the walk reaches OLDFIX
echo $(( $(date +%s) - 3600 )) > "$STATE/main-heads-since"   # the rule's first run: an hour ago (OLDFIX is older)
S=$(commit src/s.ts "dev change blocked on dev
Thread: $A")
F=$(commit src/s.ts "tests-only fix of S
Review-Fix-Of: $S
Thread: $A")
g checkout -q -b side "$X"; SIDE=$(commit src/side.ts "side
Thread: $A"); g checkout -q main
g merge -q --no-ff -m "train merge" -m "Train-Merge: $SIDE" side; TMS=$(g rev-parse HEAD)   # its review job was skipped
g push -q origin HEAD:refs/heads/main; g fetch -q origin
# runs: F blocked (6), TMS skipped review job (7), OLDFIX blocked (8)
cat > "$T/runs.json" <<J
[{"databaseId":6,"displayTitle":"recheck $F","status":"completed"},{"databaseId":7,"displayTitle":"recheck $TMS","status":"completed"},{"databaseId":8,"displayTitle":"recheck $OLDFIX","status":"completed"}]
J
gh() { local q="" a; for a in "$@"; do if [ "$q" = next ]; then q=$a; break; fi; if [ "$a" = -q ]; then q=next; fi; done
  if [ -n "$q" ] && [ "$q" != next ]; then gh_raw "$@" | jq -r "$q"; else gh_raw "$@"; fi; }
blocked='{"jobs":[{"name":"tests","id":60,"conclusion":"success"},{"name":"review","id":61,"conclusion":"failure","steps":[{"name":"Review (blocking; x)","conclusion":"failure"}]}]}'
passed='{"jobs":[{"name":"tests","id":60,"conclusion":"success"},{"name":"review","id":61,"conclusion":"success","steps":[{"name":"Review (blocking; x)","conclusion":"success"}]}]}'
gh_raw() { case "$*" in
  "run list"*) cat "$T/runs.json" ;;
  *runs/6/jobs*|*runs/8/jobs*) if [ -e "$T/f-passed" ]; then echo "$passed"; else echo "$blocked"; fi ;;
  *runs/7/jobs*) echo '{"jobs":[{"name":"tests","id":70,"conclusion":"success"},{"name":"review","id":71,"conclusion":"skipped","steps":[]}]}' ;;
  *jobs/61/logs*) printf '2026-11-13T00:00:00Z review-range: %s %s\n2026-11-13T00:00:00Z review-gate: FINDING #1 route=fixer commit=- — x\n2026-11-13T00:00:00Z review-gate: BLOCKED #1 regression [should]: s drops rows\n2026-11-13T00:00:00Z evidence: src/s.ts:1 x\n' "$X" "$F" ;;
  *"runs/6 "*|*"runs/8 "*) if [ -e "$T/f-passed" ]; then echo '{"conclusion":"success"}'; else echo '{"conclusion":"failure"}'; fi ;;
  *"runs/7 "*) echo '{"conclusion":"success"}' ;;
  *) echo '{}' ;; esac; }
notify() { if [ -e "$STATE/sent/$1.$2" ]; then notify_outcome=dup; [ "$(head -1 "$STATE/sent/$1.$2")" = skipped ] && notify_outcome=skipped; return 0; fi
  echo "$1 $2 $3" >> "$T/sent"; notify_outcome=skipped; echo skipped > "$STATE/sent/$1.$2"; }   # the owner is unreachable → the fixer
notify_best_effort() { notify "$@" || :; }
wake_fixer() { [ -e "$STATE/sent/$1.fixer-$2" ] && return 0; echo "$1 $2" >> "$T/woken"; echo "$FX" > "$STATE/sent/$1.fixer-$2"; }
fixer_ended() { return 1; }

# 1. the blocked main re-check of the Review-Fix-Of: head F reaches a fixer; the skipped train merge is done quietly
eval "$loop"
grep -q "^$F mainfix-" "$T/woken" 2>/dev/null || fail "a blocked main re-check of a Review-Fix-Of: head was not handled (no fixer)"
test -e "$STATE/sent/$TMS.hotfix-complete" || fail "a Train-Merge head whose review job was skipped was not marked done"
if grep -q "^$TMS" "$T/woken" "$T/sent" 2>/dev/null; then fail "a skipped-review train merge got a notice or a fixer"; fi
if grep -q "^$OLDFIX" "$T/woken" "$T/sent" 2>/dev/null; then fail "a Review-Fix-Of: head from before the rule's first run was dug up"; fi
echo 'ok - blocked Review-Fix-Of: re-check → fixer; skipped train merge done quietly; no backlog'

# 2. a passed main re-check of the head completes it
rm -f "$STATE/sent/$F.hotfix-complete"; touch "$T/f-passed"
eval "$loop"
test -e "$STATE/sent/$F.hotfix-complete" || fail "a passed main re-check of a Review-Fix-Of: head did not complete it"
echo 'ok - passed Review-Fix-Of: re-check completes the head'

# 3. a superseded hotfix is covered by the Review-Fix-Of: head's completed batched re-check (recheck_covering)
rc_heads_built=""; declare -A rc_heads=(); declare -A cov_base=(); hotfix_runs=""
out=$(recheck_covering "$S") || fail "recheck_covering does not accept a Review-Fix-Of: head as the covering re-check"
[ "${out%% *}" = "$F" ] || fail "covering head is ${out%% *}, not $F"
echo 'review-dispatch main heads checks passed'
