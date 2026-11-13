#!/usr/bin/env bash
# The review machinery of a repository: what selects or runs its tests and its review — every file under .github/
# (the caller workflow and its sheepdog pin, the trusted test list .github/sheepdog/tests.sh, .github/sheepdog.yml),
# reviewer/ and scripts/ci/ (sheepdog's own reviewer, contract scripts and dispatcher; an adopter's own CI scripts).
# A change there must never reach the default branch on a TESTS-ONLY approval (a devfix landing, a tests-only fix
# round): the next default-branch run would already execute the replacement — e.g. a new `uses: …@<sha>` pin selects
# the workflow that is supposed to check it (review of dev a171d3396 #1/#2). Sourced by review-dispatch.sh and
# merge-branch.sh.
REVIEW_MACHINERY_RE='^(\.github/|reviewer/|scripts/ci/)'
# landing_machinery_files <git dir> <main> <head> → the machinery files whose content on <main> would change if <head>
# landed: the TREES are compared (review of dev c1dcca119 #1-#3: a commit list missed the blocked base's own changes,
# and a merge's combined diff missed a rollback to an older parent's file). The landing tree is <head>'s when <main> is
# its ancestor (fast-forward), else the automatic merge of the two (a Train-Merge); when that merge conflicts, every
# machinery file <head>'s side changed since the merge base (no automatic landing happens then, but stay conservative).
landing_machinery_files() {
  local g=$1 main=$2 head=$3 tree mb
  if git -C "$g" merge-base --is-ancestor "$main" "$head" 2>/dev/null; then tree=$(git -C "$g" rev-parse "$head^{tree}")
  elif tree=$(git -C "$g" merge-tree --write-tree "$main" "$head" 2>/dev/null); then tree=${tree%%$'\n'*}
  else
    mb=$(git -C "$g" merge-base "$main" "$head") || { echo "(no merge base)"; return 0; }
    tree=$(git -C "$g" rev-parse "$head^{tree}"); main=$mb
  fi
  git -C "$g" diff --name-only "$main" "$tree" -- 2>/dev/null | grep -E "$REVIEW_MACHINERY_RE" | sort -u || true
}
