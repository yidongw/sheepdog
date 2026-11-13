#!/usr/bin/env bash
# A rerun may share updated_at with the previous completion. Conflicting fresh
# observations must invalidate both cached job tiers, regardless of their source.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/scripts/ci/gh-cache.sh"
source "$ROOT/scripts/ci/review-coverage.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FX=$T/fx
mkdir -p "$FX" "$T/bin"
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FX/calls"
case "$1 $2" in
  'run list') cat "$FX/list.json" ;;
  'api repos/o/r/actions/runs/7') cat "$FX/record.json" ;;
  'api repos/o/r/actions/runs/7/jobs') cat "$FX/jobs.json" ;;
  'api repos/o/r/actions/workflows/review.yml/runs') cat "$FX/page.json" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
review_api() { gh api "repos/o/r/$1"; }
observe() {
  case "$1" in
    list) gh run list -R o/r --json databaseId,status,updatedAt >/dev/null ;;
    record) gh api repos/o/r/actions/runs/7 >/dev/null ;;
    page) gh api repos/o/r/actions/workflows/review.yml/runs >/dev/null ;;
  esac
}
fixtures() {
  jq -nc --arg st "$1" '[{databaseId:7,status:$st,updatedAt:"2026-11-13T10:00:00Z"}]' > "$FX/list.json"
  jq -nc --arg st "$1" '{id:7,status:$st,updated_at:"2026-11-13T10:00:00Z"}' > "$FX/record.json"
  jq -nc --slurpfile r "$FX/record.json" '{workflow_runs:$r}' > "$FX/page.json"
  jq -nc --arg st "$1" '{jobs:[{id:71,name:"sheepdog / review",status:$st,
    conclusion:(if $st == "completed" then "success" else null end),
    steps:[{name:"Review (blocking; test)",conclusion:(if $st == "completed" then "success" else null end)}]}]}' > "$FX/jobs.json"
}

for sources in 'record list' 'list record' 'record page' 'page record' 'list page' 'page list'; do
  read -r first second <<<"$sources"
  for tier in memo disk; do
    for status in in_progress queued; do
      label="$first/$second/$tier/$status"
      ghc_init "$T/cache-$first-$second-$tier-$status"
      fixtures completed
      observe "$first"
      [ "$(review_verdict 7)" = pass ] || fail "$label: setup did not pass"
      jobs_key=$(ghc_key repos/o/r/actions/runs/7/jobs)
      [ -f "$GHC_DIR/disk/$jobs_key" ] || fail "$label: setup did not cache completed jobs"
      if [ "$tier" = disk ]; then
        rm "$GHC_RUN/api.$jobs_key" "$GHC_RUN/api.$jobs_key.st"
      fi
      fixtures "$status"
      observe "$second"
      : > "$FX/calls"
      if verdict=$(review_verdict 7); then
        fail "$label: reused the previous attempt's verdict ($verdict) despite a tied rerun observation"
      fi
      grep -qxF 'api repos/o/r/actions/runs/7/jobs' "$FX/calls" || fail "$label: current jobs were not fetched"
      [ "$(ghc_run_state 7)" = "$status 2026-11-13T10:00:00Z" ] || fail "$label: completed won the timestamp tie"
      ghc_done
    done
  done
done

# Agreeing completions remain cacheable; a strictly newer completion wins over
# older active observations. Local write order or freshness must not decide ties.
ghc_init "$T/controls"
fixtures completed
cp "$FX/list.json" "$GHC_RUN/list.control"
cp "$FX/record.json" "$GHC_RUN/api.control"
[ "$(ghc_run_state 7)" = 'completed 2026-11-13T10:00:00Z' ] || fail 'agreeing completions were rejected'
[ "$(review_verdict 7)" = pass ] || fail 'agreeing completions did not pass'
: > "$FX/calls"
[ "$(review_verdict 7)" = pass ] && [ ! -s "$FX/calls" ] || fail 'agreeing completions did not reuse cached jobs'
fixtures in_progress
cp "$FX/list.json" "$GHC_RUN/list.control"
touch -d '-20 seconds' "$GHC_RUN/list.control"
[ "$(ghc_run_state 7)" = 'in_progress 2026-11-13T10:00:00Z' ] || fail 'a later local completion write won a timestamp tie'
jq '.updated_at = "2026-11-13T10:00:01Z"' "$FX/record.json" > "$GHC_RUN/api.control"
[ "$(ghc_run_state 7)" = 'in_progress 2026-11-13T10:00:01Z' ] || fail 'a newer active version was ignored'
jq '.status = "completed" | .updated_at = "2026-11-13T10:00:02Z"' "$FX/record.json" > "$GHC_RUN/api.control"
[ "$(ghc_run_state 7)" = 'completed 2026-11-13T10:00:02Z' ] || fail 'an older active version overrode a newer completion'
echo 'PASS: tied rerun observations invalidate memo/disk jobs across all sources; completion controls pass'
