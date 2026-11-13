#!/usr/bin/env bash
# MAIN→dev merges wait while the dev head's review is running (supervisor 11-12: every main hotfix made a new dev head and
# cancelled the running dev review; dev went 3 h without a finished round). At most MAINMERGE_DEFER_MAX_SEC.
set -euo pipefail
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }   # gh-cache.sh (the per-run memo of review-dispatch.sh): here the fake gh itself
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
# Any command that is not found — a dispatcher helper the test did not extract — fails the whole test at once, even
# inside an if / || condition (review of 02828988f #7: "culprits_repaired: command not found" printed, test exited 0).
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
D=$PWD/scripts/ci/review-dispatch.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
block=$(python3 - "$D" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('# ── dev: keep it a descendant of main')
b = s.index('\n# ──', a + 10)
print(s[a:b])
PY
)
eval "$(sed -n '/^dispatch_msg() {/,/^}/p' "$D")"; for _f in dispatch_msg; do declare -F "$_f" >/dev/null || { echo "missing helper $_f" >&2; exit 1; }; done
git init -q --bare "$T/remote.git"; git clone -q "$T/remote.git" "$T/src" 2>/dev/null
g() { git -C "$T/src" -c user.name=t -c user.email=t@t "$@"; }
echo a > "$T/src/a"; g add a; g commit -qm base; g branch -M main; g push -q origin main
g checkout -qb dev; echo d > "$T/src/d"; g add d; g commit -qm dev1; g push -q origin dev
g checkout -q main; echo h > "$T/src/h"; g add h; g commit -qm hotfix; g push -q origin main; g fetch -q origin
SRC=$T/src STATE=$T/state WORK=$T/work MAIN=main DEV=dev REPO=x/y DISPATCH_THREAD=00000000-0000-4000-8000-0000000000c1
mkdir -p "$STATE/sent"; LOG=$T/log; log() { echo "$*" >> "$LOG"; }
DSHA=$(g rev-parse origin/dev)
RUNS=""; dev_round_running() { [ -n "$RUNS" ]; }   # its provenance: test/ci/review-dispatch-defer-provenance.sh
# 1. the dev head's review is running → no merge, logged once
RUNS="in_progress"$'\n'
eval "$block"; eval "$block"
g fetch -q origin; test "$(g rev-parse origin/dev)" = "$DSHA"
test "$(grep -c 'deferred: the review of dev' "$LOG")" -eq 1
# 2. waited longer than the cap → merges anyway — also when dev got a NEW head meanwhile (re-check of 6977d5574 #1: the
#    deadline was keyed by the dev sha, so every new dev head restarted it and continuous dev pushes deferred forever)
MSHA=$(g rev-parse origin/main)
echo $(( $(date +%s) - 3000 )) > "$STATE/sent/mainmerge-wait.$MSHA"
g checkout -q dev; echo d2 > "$T/src/d2"; g add d2; g commit -qm dev2; g push -q origin dev; g checkout -q main; g fetch -q origin
DSHA=$(g rev-parse origin/dev)
eval "$block"; g fetch -q origin; test "$(g rev-parse origin/dev)" != "$DSHA"; grep -q 'merging now' "$LOG"
test ! -e "$STATE/sent/mainmerge-wait.$MSHA"                    # removed once the merge is pushed
# 3. nothing running → merges at once
g push -q -f origin "$DSHA:refs/heads/dev"; g fetch -q origin; rm -f "$STATE"/sent/*; : > "$LOG"; RUNS=""
eval "$block"; g fetch -q origin; test "$(g rev-parse origin/dev)" != "$DSHA"; grep -q 'MAIN→dev merged main' "$LOG"
echo 'main→dev merge waits for the running dev review (capped)'
