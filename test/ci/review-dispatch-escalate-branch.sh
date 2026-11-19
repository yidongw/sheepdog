#!/usr/bin/env bash
# Execute the generated escalation task's checkout commands in a real worktree with two failed fixes.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main DEV=dev
DEV_ESCALATE_AFTER_MIN=60 STRONG_FIXER_EFFORT=medium STRONG_FIXER_EFFORT_ESCALATED=high
STRONG_FIXER_PROVIDER=test STRONG_FIXER_MODEL=test
mkdir -p "$STATE/sent"
for fn in dev_escalate devfix_failed_tests; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$ROOT/scripts/ci/review-dispatch.sh")"
  declare -F "$fn" >/dev/null || fail "missing $fn"
done
budget_spent() { return 1; }
author_window_open() { return 1; }
log() { :; }
wake_fixer() { printf '%s\n' "$4" > "$T/task"; }

git init -q -b dev "$SRC"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
g commit -q --allow-empty -m dev
D=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/dev "$D"
g checkout -q -b failed-fixes
printf 'echo F1\nexit 1\n' > "$SRC/failed-test.sh"
g add failed-test.sh; g commit -q -m F1; F1=$(g rev-parse HEAD)
printf 'echo F2\nexit 1\n' > "$SRC/failed-test.sh"
g add failed-test.sh; g commit -q -m F2; F2=$(g rev-parse HEAD)
printf '%s\n' "$F1" "$F2" > "$STATE/sent/$D.devfix-fails"
printf '%s\n' "$F2" > "$STATE/sent/$D.devfix-unresolved"
dev_escalate "$D" 'review-gate: BLOCKED #1 regression [should]: fixture' 'https://example.invalid/run' ''
for sha in "$F1" "$F2"; do
  grep -q "fix $sha .* failed the trusted tests" "$T/task" || fail "task omitted failed fix $sha"
done

allocated=devfix-${D:0:9}-devstrong-1
g worktree add -q -b "$allocated" "$T/fixer" origin/dev
cd "$T/fixer"
# Read commands from the generated task, so a regression to checkout - exercises Git's actual behavior.
save=$(sed -n 's/.*(\(fixer_branch=.*\)). Keep that variable.*/\1/p' "$T/task")
back=$(sed -n '/^Your worktree starts /s/.*(\(git checkout [^;]*\); never git checkout -B.*/\1/p' "$T/task")
test -n "$back" || fail "task has no return checkout command"
if [ -n "$save" ]; then eval "$save"; fi
for sha in "$F1" "$F2"; do
  git checkout -q --detach "$sha"
  test "$(git rev-parse HEAD)" = "$sha" || fail "wrong reproduction commit"
  if bash failed-test.sh > "$T/test-output" 2>&1; then fail "fixture unexpectedly passed"; fi
  grep -qx "$(git log -1 --format=%s)" "$T/test-output" || fail "did not reproduce this fix"
done
eval "$back" >/dev/null 2>&1
actual=$(git symbolic-ref --quiet --short HEAD || true)
test "$actual" = "$allocated" || fail "after two failed fixes, expected $allocated; got ${actual:-detached HEAD} at $(git rev-parse --short HEAD)"
test "$(git rev-parse HEAD)" = "$D" || fail "repair starts from a failed fix instead of origin/dev"
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m repair
test "$(git rev-parse HEAD^)" = "$D" || fail "repair has the wrong parent"
git worktree list --porcelain | grep -qx "branch refs/heads/$allocated" || fail "worktree is invisible to branch-based cleanup"
test -n "$save" || fail "task did not capture the allocated branch before reproducing"
echo 'ok - two failed fixes reproduced detached; saved allocated branch restored; repair parent is dev; cleanup sees the branch'
