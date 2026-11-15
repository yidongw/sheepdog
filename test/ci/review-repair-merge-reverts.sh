#!/usr/bin/env bash
# A trailer repair D of blocked C enters a sibling merge. Reverting that merge
# removes D without naming it. Every repair consumer must withhold its privilege.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
. "$(dirname "$0")/../../scripts/ci/test-review-fixtures.sh"
. "$CI/review-repair.sh"
# Extract the real dispatcher helpers without starting its production loop.
for fn in fix_reverted repair_effective thread_of norm_tid; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$CI/review-dispatch.sh")"
done
SRC=$T/src
bad=0
check() { if ! "$@"; then echo "FAIL: $*" >&2; bad=1; fi; }
absent() { if "$@" >/dev/null; then echo "FAIL: unexpectedly accepted: $*" >&2; return 1; fi; }
commit_file() {
  printf '%s\n' "$2" > "$3"; g add "$3"
  g commit -q -m "$1" ${4:+-m "$4"}; git rev-parse HEAD
}
repair_state() { # <0 present|1 absent> <target> <head>
  if [ "$1" = 0 ]; then
    check repaired "$2" "$3"
    check repair_effective "$2" '' "$3"
  else
    check absent repaired "$2" "$3"
    check absent repair_effective "$2" '' "$3"
  fi
}
P=$(commit_file production baseline bug)
git update-ref refs/remotes/origin/main "$P"
C=$(commit_file 'blocked C' broken bug)
D=$(commit_file 'trailer repair D' fixed bug "Review-Fix-Of: $C")
repair_state 0 "$C" "$D"
# Preserve existing direct-revert semantics and unrelated non-merge reverts.
W=$(commit_file unrelated side side)
g revert --no-edit "$W" >/dev/null
repair_state 0 "$C" HEAD
g checkout -q --detach "$D"
g revert --no-edit "$D" >/dev/null
repair_state 1 "$C" HEAD
g revert --no-edit HEAD >/dev/null
repair_state 0 "$C" HEAD

for mainline in 1 2; do
  g checkout -q --detach "$C"
  Q=$(commit_file 'sibling work' sibling sibling)
  if [ "$mainline" = 1 ]; then side=$D; else g checkout -q --detach "$D"; side=$Q; fi
  g merge -q --no-ff -m 'merge containing D' "$side"
  M=$(git rev-parse HEAD)
  repair_state 0 "$C" "$M"
  g revert --no-edit -m "$mainline" "$M" >/dev/null
  U=$(git rev-parse HEAD)
  [ "$(cat bug)" = broken ] || fail 'merge undo did not remove D'
  # Git names M, never D, in this actual merge revert.
  msg=$(git show -s --format=%B "$U")
  grep -qx "This reverts commit $M, reversing" <<<"$msg" || fail 'missing merge marker'
  if grep -qF "This reverts commit $D" <<<"$msg"; then fail 'fixture directly names D'; fi
  repair_state 1 "$C" "$U"
  # Each ref is judged separately; D still stands at the un-reverted merge.
  check repair_effective "$C" '' "$U" "$M"
  check absent repair_effective "$C" '' "$U" "^$M"
  # Even undoing the merge undo requires a fresh repair or full review. Do
  # not reintroduce the retired retained-contribution/restoration proofs.
  g revert --no-edit "$U" >/dev/null
  [ "$(cat bug)" = fixed ] || fail 'merge redo did not restore D'
  repair_state 1 "$C" HEAD
  g checkout -q --detach "$U"
  E=$(commit_file 'later blocked E' broken later)
  F=$(commit_file 'trailer repair F' fixed later "Review-Fix-Of: $E")
  reset
  run 1 "review $C" success failure "$P" '' blocked
  run 2 "review $D" success skipped "$C" tests-only-fix
  run 3 "review $E" success failure "$C" '' blocked
  run 4 "review $F" success skipped "$E" tests-only-fix
  repair_state 0 "$E" "$F"
  # dev reviews each commit once (owner 11-15): F repairs E — a tests-only round — and the next range starts at E; the
  # removed repair of C is caught by approval: C is no link of F's coverage chain without an effective repair
  check bash "$CI/dev-review-base.sh" --only-fixes "$E" "$F"
  check absent RP "$F" o/r "$P"
  cover=$(bash "$CI/dev-review-base.sh" "$F" 2>"$T/base.err")
  [ "$cover" = "$E" ] || { echo "FAIL: F's range does not start at the completed review of E (got $cover)" >&2; bad=1; }
  review_api() { curl -fsSL "https://api.github.com/repos/$REPO/$1"; }
  . "$CI/review-runs.sh"; . "$CI/review-coverage.sh"
  check absent review_link 1 "$C" "$P" "$F" 0

  # A NEW explicit repair can replace the invalidated D. It is newer than
  # the merge revert and has no merge revert after it.
  G=$(commit_file 'new repair of C' fixed bug "Review-Fix-Of: $C")
  repair_state 0 "$C" "$G"
  check bash "$CI/dev-review-base.sh" --only-fixes "$E" "$G"
  run 5 "review $G" success skipped "$E" tests-only-fix
  check RP "$G" o/r "$P"

  # and later rounds keep working above the new repair
  J=$(commit_file 'next blocked review' broken next)
  run 8 "review $J" success failure "$G" '' blocked
  K=$(commit_file 'repair next review' fixed next "Review-Fix-Of: $J")
  check bash "$CI/dev-review-base.sh" --only-fixes "$J" "$K"
  run 9 "review $K" success skipped "$J" tests-only-fix
  check RP "$K" o/r "$P"   # through the tests-only round G (a verified link)
  echo "exercised mainline $mainline: removed trailer repair, both gates, dispatcher, fresh repair"
done
# review of sheepdog ae795a369 / 43721cf57 #1: a git error deep in the revert recursion is UNKNOWN, never "the undo was
# itself reverted" — the undone repair R does not count, for review-repair.sh and the dispatcher alike
g checkout -q --detach "$P"
S2=$(commit_file 'blocked S2' broken2 bug2)
R2=$(commit_file 'repair R2' fixed2 bug2 "Review-Fix-Of: $S2")
g revert --no-edit "$R2" >/dev/null; U2=$(git rev-parse HEAD)
repair_state 1 "$S2" "$U2"                        # control: the plain undo is seen
git() { case "$*" in *"This reverts commit $U2"*) return 128 ;; esac; command git "$@"; }
check absent repaired "$S2" "$U2"
rc=0; reverted "$R2" "$U2" || rc=$?
[ "$rc" = 2 ] || { echo "FAIL: reverted() answered $rc, not unknown (2), on a git error" >&2; bad=1; }
check absent repair_effective "$S2" '' "$U2"
unset -f git
echo "exercised: a git error in the nested revert query → unknown → no repair"
[ "$bad" = 0 ] || fail 'merge-reverted trailer repair still eligible'
