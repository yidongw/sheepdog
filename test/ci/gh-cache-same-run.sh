#!/usr/bin/env bash
# Keep the original equal-timestamp/source-order protection across cache designs.
# No cache cleanup occurs between a passing attempt and its observed rerun.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/scripts/ci/gh-cache.sh"
source "$ROOT/scripts/ci/review-coverage.sh"
T=$(mktemp -d); trap 'ghc_done; rm -rf "$T"' EXIT
export FX=$T/fx
mkdir -p "$FX" "$T/bin"
cat > "$T/bin/gh" <<'BACKEND'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FX/calls"
case "$*" in
  'run list '*) cat "$FX/list" ;;
  'api repos/o/r/actions/runs/7') cat "$FX/record" ;;
  'api repos/o/r/actions/runs/7/jobs') cat "$FX/jobs" ;;
  'api repos/o/r/actions/workflows/review.yml/runs') cat "$FX/page" ;;
  'api repos/o/r/actions/jobs/72/logs') echo 'review-gate: BLOCKED #1 regression [should]: rerun failed' ;;
  *) exit 1 ;;
esac
BACKEND
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
review_api() { gh api "repos/o/r/$1"; }
# Compatible with the pre-split cache, so the same test proves the old failure.
memo() { if declare -F ghm >/dev/null; then ghm "$@"; else gh "$@"; fi; }
observe() {
  local client=$1 source=$2
  case "$source" in
    record) "$client" api repos/o/r/actions/runs/7 ;;
    page) "$client" api repos/o/r/actions/workflows/review.yml/runs ;;
    list) "$client" run list -R o/r --json databaseId,status,conclusion,updatedAt ;;
  esac
}
fixtures() {
  # A rerun may have exactly the same timestamp as the previous completion.
  jq -nc --arg s "$1" --arg c "$2" '{id:7,status:$s,conclusion:(if $c == "null" then null else $c end),updated_at:"2026-11-13T10:00:00Z"}' > "$FX/record"
  jq '[. | {databaseId:.id,status,conclusion,updatedAt:.updated_at}]' "$FX/record" > "$FX/list"
  jq '{workflow_runs:[.]}' "$FX/record" > "$FX/page"
  jq -nc --arg s "$1" --arg c "$2" '{jobs:[{id:(if $c == "success" then 71 else 72 end),name:"sheepdog / review",status:$s,conclusion:(if $c == "null" then null else $c end),
    steps:[{name:"Review (blocking; test)",conclusion:(if $c == "null" then null else $c end)}]}]}' > "$FX/jobs"
}
for sources in 'record list' 'list record' 'record page' 'page record' 'list page' 'page list'; do
  read -r first second <<< "$sources"
  for status in failure in_progress queued; do
    ghc_init "$T/$first-$second-$status"
    fixtures completed success
    observe memo "$first" >/dev/null
    memo api repos/o/r/actions/runs/7/jobs >/dev/null
    [ "$(review_verdict 7)" = pass ] || fail "$sources/$status: setup did not pass"
    if [ "$status" = failure ]; then fixtures completed failure; expected=blocked
    else fixtures "$status" null; expected=none; fi
    observe gh "$second" > "$T/observed"
    grep -q "$status" "$T/observed" || fail "$sources/$status: rerun not observed"
    : > "$FX/calls"
    verdict=$(review_verdict 7) || verdict=none
    [ "$verdict" = "$expected" ] || fail "$sources/$status: stale approval '$verdict' after a fresh rerun observation"
    grep -qxF 'api repos/o/r/actions/runs/7/jobs' "$FX/calls" || fail "$sources/$status: jobs were not fetched again"
    ghc_done
  done
done
echo 'ok - equal-timestamp reruns reject old approval for every record/page/list source order (failed, active, queued)'
