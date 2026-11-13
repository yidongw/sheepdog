#!/usr/bin/env bash
# A cancelled trusted-tests job is not a finding (11-13: the dispatcher's own "tests no longer needed" cancellation was
# sent to a fixer as something to fix). A failed one still is.
set -euo pipefail
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }   # gh-cache.sh (the per-run memo of review-dispatch.sh): here the fake gh itself
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
eval "$(sed -n '/^findings_cap() {/,/^}/p; /^findings() {/,/^}/p' scripts/ci/review-dispatch.sh)"; for _f in findings_cap findings; do declare -F "$_f" >/dev/null || { echo "missing helper $_f" >&2; exit 1; }; done
REPO=x/y
gh() { case "$*" in
  *"/runs/1/jobs"*) echo '{"jobs":[{"name":"tests","conclusion":"cancelled","id":11},{"name":"review","conclusion":"failure","id":12}]}' ;;
  *"/runs/2/jobs"*) echo '{"jobs":[{"name":"tests","conclusion":"failure","id":21},{"name":"review","conclusion":"failure","id":22}]}' ;;
  *"/jobs/12/logs"*|*"/jobs/22/logs"*) printf '%s\n' "2026-11-13T00:00:00Z review-gate: BLOCKED #1 regression [should]: bug" "2026-11-13T00:00:00Z evidence: a.ts:1 x" ;;
  *"/jobs/21/logs"*) echo "2026-11-13T00:00:00Z  FAIL test/a.test.ts" ;;
  *) echo '{}' ;; esac; }
out=$(findings 1); grep -q 'BLOCKED #1' <<<"$out"; if grep -q 'trusted tests job' <<<"$out"; then echo 'cancelled tests reported as a finding' >&2; exit 1; fi
out=$(findings 2); grep -q 'trusted tests job: failure' <<<"$out"
echo 'cancelled tests are not a finding; failed tests are'
# A called workflow's jobs ("sheepdog / tests", "sheepdog / review"): the same findings
gh() { case "$*" in
  *"/runs/3/jobs"*) echo '{"jobs":[{"name":"sheepdog / tests","conclusion":"failure","id":31},{"name":"sheepdog / review","conclusion":"failure","id":32}]}' ;;
  *"/jobs/32/logs"*) printf '%s\n' "2026-11-13T00:00:00Z review-gate: BLOCKED #1 regression [should]: bug" "2026-11-13T00:00:00Z evidence: a.ts:1 x" ;;
  *"/jobs/31/logs"*) echo "2026-11-13T00:00:00Z  FAIL test/a.test.ts" ;;
  *) echo '{}' ;; esac; }
out=$(findings 3); grep -q 'BLOCKED #1' <<<"$out"; grep -q 'trusted tests job: failure' <<<"$out"
echo 'called-workflow job names: the same findings'
