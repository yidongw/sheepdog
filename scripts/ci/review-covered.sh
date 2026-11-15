#!/usr/bin/env bash
# review-covered.sh <base> <anchor> <head> [owner/repo] → exit 0 when <base> is covered for <head> from <anchor>: <base> is
# an ancestor of <anchor>, or the chain of completed, attested reviews (review-coverage.sh review_covered — trusted runs
# only, an unrepaired blocked review is no link) reaches from <base> down to <anchor>. The dispatcher's devfix landing
# asks it for the blocked sha S a fix repairs: S's own range starts at the review before it (dev reviews each commit once,
# whatever that review's verdict), so S + its fix land only when every commit below S is covered too.
# Run in a clone holding all three commits. GH_TOKEN; [owner/repo] defaults to $REPO; the default branch to
# $REVIEW_DEFAULT_BRANCH, then $MAIN_BRANCH, then main.
set -euo pipefail
b=$(git rev-parse --verify "${1:?usage: review-covered.sh <base> <anchor> <head> [owner/repo]}^{commit}")
a=$(git rev-parse --verify "${2:?usage: review-covered.sh <base> <anchor> <head> [owner/repo]}^{commit}")
h=$(git rev-parse --verify "${3:?usage: review-covered.sh <base> <anchor> <head> [owner/repo]}^{commit}")
repo="${4:-${REPO:?usage: review-covered.sh <base> <anchor> <head> [owner/repo] (or REPO=owner/name)}}"
git merge-base --is-ancestor "$b" "$h" || { echo "${b:0:12} is not an ancestor of ${h:0:12}" >&2; exit 1; }
REVIEW_DEFAULT_BRANCH=${REVIEW_DEFAULT_BRANCH:-${MAIN_BRANCH:-main}}
review_api() { gh api "repos/$repo/$1"; }
REVIEW_LINK_FIXES=1 REVIEW_REPO=$repo   # verified tests-only rounds are links (the devfix head re-checks on main)
. "$(dirname "${BASH_SOURCE[0]}")/review-runs.sh"
. "$(dirname "${BASH_SOURCE[0]}")/review-coverage.sh"
if review_covered "$b" "$a" "$h"; then echo "covered: ${b:0:12} for ${h:0:12} from ${a:0:12}"; exit 0; fi
echo "not covered: ${b:0:12} for ${h:0:12} from ${a:0:12} (a blocked review below it without its repair, or missing proof)" >&2
exit 1
