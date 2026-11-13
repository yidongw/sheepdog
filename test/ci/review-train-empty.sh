#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
# Any command that is not found — a dispatcher helper the test did not extract — fails the whole test at once, even
# inside an if / || condition (review of 02828988f #7: "culprits_repaired: command not found" printed, test exited 0).
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
script=$PWD/scripts/ci/review-dispatch.sh
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
git init -q "$fixture"
cd "$fixture"
git config user.email test@example.com
git config user.name test
printf 'base\n' > file
git add file; git commit -qm base
git branch main
printf 'feature\n' > file
git commit -qam feature
feature=$(git rev-parse HEAD)
git revert --no-edit "$feature" >/dev/null
revert=$(git rev-parse HEAD)
git checkout -q main
printf 'hotfix\n' > hotfix
git add hotfix; git commit -qm hotfix
git update-ref refs/remotes/origin/main HEAD
SRC=$fixture MAIN=main STATE=$fixture/state DEV=dev
mkdir -p "$STATE/sent"
log() { :; }
guard=$(sed -n '/^      mt=""/,/^      # main got a hotfix/{ /^      # main got a hotfix/d; p; }' "$script")
visited=0
for tsha in "$revert" "$feature"; do
  visited=$((visited + 1))
  eval "$guard"
done
test "$visited" = 1
# A conflicting candidate must survive the probe and reach subsequent handling.
git checkout -q --detach "$feature"
printf 'conflicting hotfix\n' > file
git commit -qam conflict
git update-ref refs/remotes/origin/main HEAD
reached=0
for tsha in "$revert"; do
  eval "$guard"
  reached=1
done
test "$reached" = 1
echo 'train empty/revert and conflict regression checks passed'
