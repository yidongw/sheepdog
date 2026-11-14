#!/usr/bin/env bash
# Real git merge-revert regressions for supersession (foxhole-backend b96e6e4ef #1/#2).
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
PIN=source
. "$(dirname "$0")/../../scripts/ci/test-review-fixtures.sh"
  commit_file() {
    printf '%s\n' "$2" > "$3"
    g add "$3"; g commit -q -m "$1"
    git rev-parse HEAD
  }
  only_fixes() { bash "$CI/dev-review-base.sh" --only-fixes "$1" "$2"; }
  verdicts() {
    reset
    run 1 "review $C" success failure "$P" '' blocked
    run 2 "review $D" success success "$P"
    printf 'review-range: %s %s\n' "$P" "$D" > "$FX/log-1002.txt"
    run 3 "review $E" success failure "$B" '' blocked
  }
  repair_round() {
    B=$(git rev-parse HEAD)
    E=$(commit_file 'later blocked change' broken later)
    F=$(commit_file 'repair later change' fixed later)
    g commit -q --amend -m 'repair later change' -m "Review-Fix-Of: $E"
    F=$(git rev-parse HEAD)
    verdicts
  }
  P=$(commit_file production good bug)
  git update-ref refs/remotes/origin/main "$P"
  C=$(commit_file 'blocked bug' broken bug)
  D=$(commit_file 'passing repair without a repair trailer' good bug)
  repair_round
  only_fixes "$E" "$F" || fail 'standing passing review did not supersede the old block'
  echo 'ok: standing passing review permits the later repair'

  g checkout -q --detach "$D"
  g revert --no-edit "$D" >/dev/null
  R=$(git rev-parse HEAD)
  [ "$(cat bug)" = broken ] || fail 'fixture did not restore the blocked bug'
  repair_round
  if only_fixes "$E" "$F"; then fail 'reverted passing fix allowed an unrepaired block into a tests-only round'; fi
  echo 'ok: reverted passing fix requires a full review'

  g checkout -q --detach "$R"
  g revert --no-edit "$R" >/dev/null
  [ "$(cat bug)" = good ] || fail 'fixture did not restore the passing fix'
  repair_round
  only_fixes "$E" "$F" || fail 'reverting the revert did not restore valid supersession'
  echo 'ok: reverting the revert restores the evidence'

  # Git's restoring commit names a merge, rather than the revert it introduced.
  g checkout -q --detach "$D"
  g merge -q --no-ff -m 'merge the revert' "$R"
  M=$(git rev-parse HEAD)
  g revert --no-edit -m 1 "$M" >/dev/null
  git diff --exit-code "$D" HEAD || fail 'merge revert did not restore the exact passing tree'
  restored=$(git rev-parse HEAD)
  repair_round
  only_fixes "$E" "$F" || fail 'reverting a merge introducing the revert did not restore supersession'
  echo 'ok: reverting the merge with mainline 1 restores the evidence'

  # Reverting the restoring commit must invalidate the evidence again.
  g checkout -q --detach "$restored"
  g revert --no-edit "$restored" >/dev/null
  repair_round
  if only_fixes "$E" "$F"; then fail 'reverting the merge restoration retained supersession'; fi
  echo 'ok: reverting the merge restoration requires a full review'

  # Parent 2 can be the selected mainline too.
  g checkout -q --detach "$D"
  g commit -q --allow-empty -m 'other mainline'
  main2=$(git rev-parse HEAD)
  g checkout -q --detach "$R"
  g merge -q --no-ff -m 'merge with the revert on parent 1' "$main2"
  M2=$(git rev-parse HEAD)
  g revert --no-edit -m 2 "$M2" >/dev/null
  git diff --exit-code "$D" HEAD || fail 'mainline 2 did not restore the passing tree'
  repair_round
  only_fixes "$E" "$F" || fail 'mainline 2 restoration did not restore supersession'
  echo 'ok: reverting the merge with mainline 2 restores the evidence'

  # A revert on the retained mainline is not undone by reverting the merge.
  g checkout -q --detach "$D"
  side=$(commit_file 'unrelated side change' side side)
  g checkout -q --detach "$R"
  g merge -q --no-ff -m 'merge unrelated side into the revert' "$side"
  kept=$(git rev-parse HEAD)
  g revert --no-edit -m 1 "$kept" >/dev/null
  git diff --exit-code "$R" HEAD || fail 'mainline fixture did not retain the revert'
  repair_round
  if only_fixes "$E" "$F"; then fail 'merge revert undid a revert on its retained mainline'; fi
  echo 'ok: a revert on the retained mainline still requires a full review'

  # A merge revert can also remove the passing fix itself, not just restore it.
  g checkout -q --detach "$C"
  g merge -q --no-ff -m 'merge passing repair' "$D"
  introduced=$(git rev-parse HEAD)
  g revert --no-edit -m 1 "$introduced" >/dev/null
  git diff --exit-code "$C" HEAD || fail 'merge revert did not restore the blocked tree'
  repair_round
  if only_fixes "$E" "$F"; then fail 'a merge revert removing the passing fix retained supersession'; fi
  echo 'ok: reverting a merge introducing the passing repair requires a full review'

  # Conflicts can retain part of a constituent revert. Its mere membership in
  # the merge is not proof that reverting that merge fully restored the fix.
  g checkout -q --detach "$C"
  printf 'broken\nbroken\n' > bug
  g add bug; g commit -q -m 'two blocked lines'
  original_C=$C; original_D=$D; C=$(git rev-parse HEAD)
  D=$(commit_file 'passing two-line repair' $'good\ngood' bug)
  g revert --no-edit "$D" >/dev/null
  partial_R=$(git rev-parse HEAD)
  g checkout -q --detach "$D"
  partial_main=$(commit_file 'keep one blocked line' $'good\nbroken' bug)
  if g merge -q --no-ff -m 'partial merge' "$partial_R"; then fail 'expected a merge conflict'; fi
  printf 'broken\nbroken\n' > bug
  g add bug; g commit -q --no-edit
  partial_M=$(git rev-parse HEAD)
  g revert --no-edit -m 1 "$partial_M" >/dev/null
  git diff --exit-code "$partial_main" HEAD || fail 'partial fixture did not restore its mainline'
  repair_round
  if only_fixes "$E" "$F"; then fail 'partial merge restoration counted as fully undoing the revert'; fi
  echo 'ok: partial restoration requires a full review'
  C=$original_C; D=$original_D

  # A revert the covering review already saw must not invalidate that review.
  original_D=$D
  g checkout -q --detach "$C"
  X=$(commit_file 'temporary change' temporary unrelated)
  g revert --no-edit "$X" >/dev/null
  D=$(commit_file 'passing review after an earlier revert' good bug)
  repair_round
  only_fixes "$E" "$F" || fail 'a revert inside the reviewed range invalidated its passing review'
  echo 'ok: a revert covered by the passing review preserves the evidence'
  D=$original_D

  # Unknown revert state must also reject evidence, rather than interpret the
  # recursion limit as proof that the first revert has itself been undone.
  g checkout -q --detach "$R"
  previous=$R
  for ((i=2; i<=65; i++)); do
    g revert --no-edit "$previous" >/dev/null
    previous=$(git rev-parse HEAD)
  done
  [ "$(cat bug)" = broken ] || fail 'nested reverts did not restore the blocked bug'
  repair_round
  if only_fixes "$E" "$F"; then fail 'nested reverts allowed an unrepaired block into a tests-only round'; fi
  echo "ok: nested reverted passing fix requires a full review ($PIN)"
