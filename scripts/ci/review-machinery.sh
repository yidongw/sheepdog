#!/usr/bin/env bash
# The review machinery of a repository: what selects or runs its tests and its review — every file under .github/
# (the caller workflow and its sheepdog pin, the trusted test list .github/sheepdog/tests.sh, .github/sheepdog.yml),
# reviewer/ and scripts/ci/ (sheepdog's own reviewer, contract scripts and dispatcher; an adopter's own CI scripts).
# A change there must never reach the default branch on a TESTS-ONLY approval (a devfix landing, a tests-only fix
# round): the next default-branch run would already execute the replacement — e.g. a new `uses: …@<sha>` pin selects
# the workflow that is supposed to check it (review of dev a171d3396 #1/#2). Sourced by review-dispatch.sh and
# merge-branch.sh.
REVIEW_MACHINERY_RE='^(\.github/|reviewer/|scripts/ci/)'
review_machinery_files() { # review_machinery_files <git dir> <rev-list args…> → machinery files those commits change
  # merges count only with their own resolutions (--cc): what a merge brings from its parents is in their commits
  git -C "$1" log --format= --name-only --cc "${@:2}" -- 2>/dev/null | grep -E "$REVIEW_MACHINERY_RE" | sort -u || true
}
