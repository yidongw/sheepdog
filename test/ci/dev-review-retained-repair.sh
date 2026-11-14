#!/usr/bin/env bash
# A merge undo's equivalent repair must survive all the way to the candidate.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
. "$(dirname "$0")/../../scripts/ci/test-review-fixtures.sh"
commit_file() {
  printf '%s\n' "$2" > "$3"
  g add "$3"; g commit -q -m "$1"
  git rev-parse HEAD
}
bad=0
approval() { # approval <0: allow, 1: reject> <description>
  local expected=$1 description=$2 b e f actual
  b=$(git rev-parse HEAD)
  e=$(commit_file 'later blocked change' broken later)
  f=$(commit_file 'repair later change' fixed later)
  g commit -q --amend -m 'repair later change' -m "Review-Fix-Of: $e"
  f=$(git rev-parse HEAD)
  reset
  run 1 "review $C" success failure "$P" '' blocked
  run 2 "review $D" success success "$P"
  printf 'review-range: %s %s\n' "$P" "$D" > "$FX/log-1002.txt"
  run 3 "review $e" success failure "$D" '' blocked
  actual=0; bash "$CI/dev-review-base.sh" --only-fixes "$e" "$f" || actual=$?
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $description: tests-only gate returned $actual, expected $expected" >&2
    bad=1
  fi
  run 4 "review $f" success skipped "$e" tests-only-fix
  actual=0; RP "$f" o/r "$P" || actual=$?
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $description: deployment coverage returned $actual, expected $expected" >&2
    bad=1
  fi
  g checkout -q --detach "$b"
}
P=$(commit_file production good bug)
git update-ref refs/remotes/origin/main "$P"
C=$(commit_file 'blocked bug' $'broken\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12' bug)
D=$(commit_file 'passing repair' $'good\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12' bug)
side=$(commit_file 'unrelated merged file' side side)
for mainline in 1 2; do
  g checkout -q --detach "$C"
  g cherry-pick "$D" >/dev/null
  g commit -q --amend -m 'equivalent repair outside reviewed ancestry'
  Q=$(git rev-parse HEAD)
  if git merge-base --is-ancestor "$Q" "$D"; then fail 'Q must be outside the reviewed ancestry'; fi
  if [ "$mainline" = 1 ]; then
    g merge -q --no-ff -m 'merge reviewed repair and unrelated file' "$side"
  else
    g checkout -q --detach "$side"
    g merge -q --no-ff -m 'merge equivalent repair on parent 2' "$Q"
  fi
  M=$(git rev-parse HEAD)
  g revert --no-edit -m "$mainline" "$M" >/dev/null
  U=$(git rev-parse HEAD)
  git diff --exit-code "$D" "$U" || fail 'merge undo did not retain the complete repair'
  approval 0 "mainline $mainline retained repair"

  # Unrelated same-file changes at the candidate cannot invalidate the patch.
  printf 'candidate metadata\n' >> bug
  g add bug; g commit -q -m 'unrelated same-file change after the merge undo'
  approval 0 "mainline $mainline retained repair with later metadata"

  g revert --no-edit "$Q" >/dev/null
  removed=$(git rev-parse HEAD)
  [ "$(head -1 bug)" = broken ] || fail 'reverting Q did not restore the blocked bug'
  approval 1 "mainline $mainline later revert of equivalent repair"

  # Undoing U restores only the unrelated file. It cannot cancel the final
  # head's evidence that Q's repair has disappeared.
  g revert --no-edit "$U" >/dev/null
  [ "$(head -1 bug)" = broken ] || fail 'undoing U changed the blocked bug'
  approval 1 "mainline $mainline unrelated undo after the repair was removed"

  g revert --no-edit "$removed" >/dev/null
  [ "$(head -1 bug)" = good ] || fail 'reverting Q removal did not restore the repair'
  approval 0 "mainline $mainline equivalent repair restored at candidate"
  echo "ok: mainline $mainline tracks equivalent repair through the candidate head"
done
[ "$bad" = 0 ] || fail 'stale merge-undo preservation approved a missing repair'
