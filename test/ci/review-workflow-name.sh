#!/usr/bin/env bash
# The trusted Review runs are runs of ONE caller file (scripts/ci/review-runs.sh): review.yml for adopters,
# self-review.yml for sheepdog itself (SHEEPDOG_REVIEW_WORKFLOW). A run of any other file — the reusable review.yml in
# sheepdog, a branch's forged workflow — is never evidence; a name that is not a plain workflow file name is refused.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
CI=$(cd "$(dirname "$0")/../../scripts/ci" && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
review_api() { # the API path asked for is recorded; both files' runs are answered on every listing
  echo "$1" >> "$ASKED"
  case "$1" in *page=1*) ;; *) echo '{"workflow_runs":[]}'; return ;; esac
  echo '{"workflow_runs":[{"id":1,"event":"workflow_run","head_branch":"main","path":".github/workflows/review.yml","display_title":"review a"},
                          {"id":2,"event":"workflow_run","head_branch":"main","path":".github/workflows/self-review.yml","display_title":"review b"}]}'
}
ASKED=$(mktemp); trap 'rm -f "$ASKED"' EXIT
ids() { ( unset SHEEPDOG_REVIEW_WORKFLOW; [ -z "${1:-}" ] || export SHEEPDOG_REVIEW_WORKFLOW=$1; . "$CI/review-runs.sh"; review_runs | jq -r .id | tr '\n' ' ' ); }
[ "$(ids)" = "1 " ] || fail "default (review.yml): got '$(ids)'"
grep -q '^actions/workflows/review.yml/runs?' "$ASKED" || fail "default listing path: $(cat "$ASKED")"
: > "$ASKED"
[ "$(ids self-review.yml)" = "2 " ] || fail "self-review.yml: got '$(ids self-review.yml)'"
grep -q '^actions/workflows/self-review.yml/runs?' "$ASKED" || fail "self-review listing path: $(cat "$ASKED")"
for bad in '../x.yml' 'a b.yml' 'review' '.github/workflows/review.yml'; do
  if ( export SHEEPDOG_REVIEW_WORKFLOW=$bad; . "$CI/review-runs.sh" ) 2>/dev/null; then fail "workflow name '$bad' accepted"; fi
done
echo "ok - trusted runs are one caller file's (review.yml / self-review.yml); malformed names refused"
