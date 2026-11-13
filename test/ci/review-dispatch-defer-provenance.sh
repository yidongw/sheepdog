#!/usr/bin/env bash
# The main→dev merge waits only for the dev head's own round: its CI push run or its TRUSTED Review run. A run any
# branch can create (another workflow titled "review <dev sha>", a push run of another branch) never defers it.
set -euo pipefail
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }   # gh-cache.sh (the per-run memo of review-dispatch.sh): here the fake gh itself
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
eval "$(sed -n '/^review_list() {/,/^}/p; /^dev_round_running() {/,/^}/p' "$D")"
for f in review_list dev_round_running; do declare -F "$f" >/dev/null || { echo "missing helper $f" >&2; exit 1; }; done
REPO=x/y MAIN=main DEV=dev S=$(printf 'a%.0s' $(seq 40))
REV="[]" CI="[]"
gh() { case "$*" in *"-w review.yml"*) printf '%s' "$REV" ;; *"-w CI"*) printf '%s' "$CI" ;; *) echo "[]" ;; esac; }
fail() { echo "FAIL: $*" >&2; exit 1; }
! dev_round_running "$S" || fail "nothing running deferred the merge"
REV='[{"status":"in_progress","displayTitle":"review '$S'","event":"push","headBranch":"attacker"}]'
! dev_round_running "$S" || fail "an untrusted run titled review <dev sha> deferred the merge"
REV='[{"status":"in_progress","displayTitle":"review '$S'","event":"workflow_run","headBranch":"main"}]'
dev_round_running "$S" || fail "the trusted review of the dev head did not defer the merge"
REV='[]'; CI='[{"status":"queued","headSha":"'$S'","headBranch":"attacker","event":"push"}]'
! dev_round_running "$S" || fail "another branch's CI run deferred the merge"
CI='[{"status":"in_progress","headSha":"'$S'","headBranch":"dev","event":"push"}]'
dev_round_running "$S" || fail "the dev head's CI run did not defer the merge"
echo 'main→dev deferral: only the dev head trusted runs count'
