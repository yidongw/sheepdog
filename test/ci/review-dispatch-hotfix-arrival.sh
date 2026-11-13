#!/usr/bin/env bash
# The hotfix loop's 7-day window counts from a commit's arrival on main, not its committer date: a repair committed
# 10 days ago that lands on main now is handled (before: `rev-list --since=7.days` never listed it), while a commit
# that has really been on main for 10 days stays outside the window.
set -euo pipefail
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }   # gh-cache.sh (the per-run memo of review-dispatch.sh): here the fake gh itself
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fns() { local n; for n in "$@"; do sed -n "/^$n() {/,/^}/p" "$D"; done; }
eval "$(fns main_arrivals main_arrival hotfix_candidates)"
for f in main_arrivals main_arrival hotfix_candidates; do declare -F "$f" >/dev/null || { echo "missing helper $f" >&2; exit 1; }; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DRY="" MAIN_WINDOW_SEC=604800
mkdir -p "$STATE/sent"
log() { :; }
main_head_candidate() { grep -qE '^Hotfix: ' <<<"$2"; }
git init -q -b main "$SRC"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
old=$(date -d '-10 days' '+%s'); 
GIT_COMMITTER_DATE="@$old" GIT_AUTHOR_DATE="@$old" g commit -q --allow-empty -m "old hotfix, on main for 10 days" -m "Hotfix: old"; OLD=$(g rev-parse HEAD)
main_walk_base() { echo "$OLD"; }   # the walk base (set once by the dispatcher)
g commit -q --allow-empty -m "recent hotfix" -m "Hotfix: recent"; A=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/main "$A"
c=$(hotfix_candidates); [ "$c" = "$A" ] || { echo "FAIL: first run: want $A, got '$c'" >&2; exit 1; }
# a repair committed 10 days ago lands on main now
g checkout -q -b side "$OLD"
GIT_COMMITTER_DATE="@$old" GIT_AUTHOR_DATE="@$old" g commit -q --allow-empty -m "old repair" -m "Hotfix: late"; R=$(g rev-parse HEAD)
g checkout -q main; g merge -q --no-ff -m "land the repair" -m "Hotfix: land" "$R"; M=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/main "$M"
c=$(hotfix_candidates | sort); want=$(printf '%s\n' "$A" "$R" "$M" | sort)
[ "$c" = "$want" ] || { echo "FAIL: the late-arriving repair is not in the window: got '$c'" >&2; exit 1; }
grep -q "^$R " "$STATE/main-arrivals"
# its age counts from arrival (hours, not 10 days)
age=$(( $(date +%s) - $(main_arrival "$R") )); [ "$age" -lt 3600 ] || { echo "FAIL: age from commit date ($age s)" >&2; exit 1; }
# DRY does not write the arrivals file
rm -f "$STATE/main-arrivals" "$STATE/main-arrivals.head"; DRY=1 hotfix_candidates >/dev/null; [ ! -e "$STATE/main-arrivals" ]
echo 'hotfix window counts from arrival on main'
