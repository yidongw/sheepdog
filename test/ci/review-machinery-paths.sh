#!/usr/bin/env bash
# landing_machinery_files (scripts/ci/review-machinery.sh) names every machinery path a landing changes: a rename out of
# a machinery directory (its source), a non-ASCII path git would quote, a plain edit; nothing outside machinery. Also
# runs scripts/ci/test-review-machinery.sh (the merge-rollback case), which no suite ran before.
# Review of twitter-monitor 489ee563e #1 (sheepdog pin bump fd2e6d749..01b2047c0).
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
cd "$(dirname "$0")/../.."
bash scripts/ci/test-review-machinery.sh
source scripts/ci/review-machinery.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g() { git -C "$t" "$@"; }
git init -q "$t"; g config user.email test@example.com; g config user.name test; g config core.quotePath true
mkdir -p "$t/.github/workflows" "$t/scripts/ci" "$t/app"
echo 'jobs: {}' > "$t/.github/workflows/review.yml"
echo 'on: push' > "$t/.github/workflows/检查.yml"
echo 'x' > "$t/scripts/ci/gate.sh"; echo 'y' > "$t/app/main.ts"
g add -A; g commit -qm base; main=$(g rev-parse HEAD)

case_of() { # <label> <expected newline list> — HEAD's landing against main
  local got; got=$(landing_machinery_files "$t" "$main" HEAD)
  [ "$got" = "$2" ] || fail "$1: expected [$2], got [$got]"
  echo "ok - $1"
  g reset -q --hard "$main"
}
g mv .github/workflows/review.yml review-disabled.yml; g commit -qm rename
case_of 'a rename out of .github/ names the source' '.github/workflows/review.yml'
g mv scripts/ci/gate.sh scripts/ci/gate2.sh; g commit -qm rename-inside
case_of 'a rename inside scripts/ci/ names both paths' $'scripts/ci/gate.sh\nscripts/ci/gate2.sh'
echo 'on: workflow_dispatch' > "$t/.github/workflows/检查.yml"; g commit -qam quoted
case_of 'a non-ASCII (quoted) path is matched raw' '.github/workflows/检查.yml'
g mv app/main.ts .github/main.ts; g commit -qm into
case_of 'a rename into .github/ names the destination' '.github/main.ts'
echo s > "$t/.github/workflows/with space.yml"; g add -A; g commit -qm space
case_of 'a path with a space is matched' '.github/workflows/with space.yml'
nl=$'\n'; echo n > "$t/.github/workflows/a${nl}b.yml"; g add -A; g commit -qm newline
[ -n "$(landing_machinery_files "$t" "$main" HEAD)" ] || fail 'a path with a newline under .github/ escaped the guard'
echo "ok - a path with a newline under .github/ is not missed"; g reset -q --hard "$main"
echo z >> "$t/app/main.ts"; g commit -qam app
case_of 'a change outside machinery names nothing' ''
echo 'all machinery path cases passed'
