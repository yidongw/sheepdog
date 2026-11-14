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
    run 3 "review $E" success failure "${1:-$B}" '' blocked
  }
  repair_round() {
    B=$(git rev-parse HEAD)
    E=$(commit_file 'later blocked change' broken later)
    F=$(commit_file 'repair later change' fixed later)
    g commit -q --amend -m 'repair later change' -m "Review-Fix-Of: $E"
    F=$(git rev-parse HEAD)
    verdicts "${1:-$B}"
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

  # Candidate merge drivers must not turn a conflicting repair into a no-op.
  # Q's final assignment disables auth; M resolves it safely, and reverting M
  # restores Q. Union (including a nested macro) and a custom driver all hide
  # the conflict in the old merge-tree proof. Check producer and consumer.
  saved_C=$C; saved_D=$D
  g checkout -q --detach "$C"
  mkdir -p config
  C=$(commit_file 'blocked auth setting' 'REQUIRE_AUTH=0' config/settings.env)
  D=$(commit_file 'passing auth repair' 'REQUIRE_AUTH=1' config/settings.env)
  auth_C=$C; auth_D=$D
  for driver in union nested-macro custom; do
    for mainline in 1 2; do
      C=$auth_C; D=$auth_D
      g checkout -q --detach "$C"
      case "$driver" in
        union) printf 'config/settings.env merge=union\n' > .gitattributes; attr=.gitattributes ;;
        nested-macro)
          printf '[attr]keep merge=union\n' > .gitattributes
          printf 'settings.env keep\n' > config/.gitattributes
          attr=.gitattributes ;;
        custom)
          printf 'settings.env merge=take-other\n' > config/.gitattributes
          git config merge.take-other.driver 'cp %B %A'
          attr=config/.gitattributes ;;
      esac
      g add "$attr" config
      g commit -q -m "candidate selects $driver merge semantics"
      Q=$(commit_file 'unsafe trailing auth assignment' $'REQUIRE_AUTH=1\nREQUIRE_AUTH=0' config/settings.env)
      if [ "$mainline" = 2 ]; then
        g checkout -q --detach "$D"
        side=$Q
      else
        side=$D
      fi
      if ! g merge -q --no-ff --no-commit "$side"; then
        [ -n "$(git ls-files -u -- config/settings.env)" ] || fail 'driver fixture merge failed'
      fi
      printf 'REQUIRE_AUTH=1\n' > config/settings.env
      g add config/settings.env; g commit -q -m 'resolve merged auth setting safely'
      M=$(git rev-parse HEAD)
      g revert --no-edit -m "$mainline" "$M" >/dev/null
      git diff --exit-code "$Q" HEAD || fail 'driver fixture did not restore unsafe mainline'
      [ "$(tail -1 config/settings.env)" = REQUIRE_AUTH=0 ] || fail 'auth is not disabled'
      repair_round "$D"
      bad=0
      if only_fixes "$E" "$F"; then
        echo "FAIL: $driver mainline $mainline hid a reverted auth repair from tests-only gate" >&2
        bad=1
      fi
      run 4 "review $F" success skipped "$E" tests-only-fix
      if RP "$F" o/r "$P"; then
        echo "FAIL: $driver mainline $mainline hid a reverted auth repair from deployment coverage" >&2
        bad=1
      fi
      [ "$bad" = 0 ] || fail 'candidate merge driver forged patch preservation'
      git config --unset-all merge.take-other.driver || true
      echo "ok: $driver mainline $mainline cannot forge patch preservation"
    done
  done
  C=$saved_C; D=$saved_D

  # D is introduced topologically, but its patch already lives on the retained
  # mainline as Q. Reverting M must remove only the unrelated side change.
  saved_C=$C; saved_D=$D
  g checkout -q --detach "$C"
  C=$(commit_file 'blocked repair with stable context' $'broken\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12' bug)
  reviewed_content=$'good\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12'
  D=$(commit_file 'passing repair with stable context' "$reviewed_content" bug)
  for mainline in 1 2; do
    for unrelated in separate-file same-file; do
      g checkout -q --detach "$D"
      if [ "$unrelated" = same-file ]; then
        printf '%s\nside\n' "$reviewed_content" > bug
        g add bug; g commit -q -m 'unrelated hunk beside the repair'
        side=$(git rev-parse HEAD)
      else
        side=$(commit_file 'unrelated side file' side side)
      fi
      g checkout -q --detach "$C"
      g cherry-pick "$D" >/dev/null
      g commit -q --amend -m 'equivalent repair on the retained mainline'
      Q=$(git rev-parse HEAD)
      if git merge-base --is-ancestor "$D" "$Q"; then fail 'cherry-pick must be a sibling, not D itself'; fi
      if [ "$mainline" = 2 ]; then g checkout -q --detach "$side"; side=$Q; fi
      g merge -q --no-ff -m 'merge a repair already cherry-picked' "$side"
      M=$(git rev-parse HEAD)
      g revert --no-edit -m "$mainline" "$M" >/dev/null
      git diff --exit-code "$D" HEAD || fail 'equivalent repair did not retain the reviewed tree'
      repair_round
      only_fixes "$E" "$F" || fail "mainline $mainline $unrelated revert invalidated a retained repair"
      echo "ok: mainline $mainline $unrelated merge revert preserves equivalent repair"
    done
  done

  # The retained tree may also have edits outside the reviewed patch. Do not
  # require whole-tree equality with D, or even equality of its entire file.
  g checkout -q --detach "$D"
  printf '%s\nside\n' "$reviewed_content" > bug
  g add bug; g commit -q -m 'side hunk'
  side=$(git rev-parse HEAD)
  g checkout -q --detach "$C"
  g cherry-pick "$D" >/dev/null
  g commit -q --amend -m 'equivalent repair on the retained mainline'
  printf '%s\n' "${reviewed_content/4/mainline}" > bug
  g add bug; g commit -q -m 'keep a separate mainline hunk'
  Q=$(git rev-parse HEAD)
  g merge -q --no-ff -m 'merge independent same-file hunks' "$side"
  M=$(git rev-parse HEAD)
  g revert --no-edit -m 1 "$M" >/dev/null
  git diff --exit-code "$Q" HEAD || fail 'same-file fixture did not restore the retained mainline'
  repair_round
  only_fixes "$E" "$F" || fail 'an unrelated retained hunk invalidated a surviving repair'
  echo 'ok: patch preservation permits unrelated retained edits in the same file'

  # Preserving only one part of the reviewed patch is insufficient. The merge
  # supplies the other repaired file, so its revert must invalidate the pass.
  g checkout -q --detach "$C"
  C=$(commit_file 'second blocked file' broken second)
  printf '%s\n' "$reviewed_content" > bug
  printf 'good\n' > second
  g add bug second; g commit -q -m 'passing repair of both files'
  D=$(git rev-parse HEAD)
  g checkout -q --detach "$C"
  Q=$(commit_file 'retain only the first repair' "$reviewed_content" bug)
  g merge -q --no-ff -m 'merge the rest of the repair' "$D"
  M=$(git rev-parse HEAD)
  g revert --no-edit -m 1 "$M" >/dev/null
  git diff --exit-code "$Q" HEAD || fail 'partial preservation did not restore its mainline'
  repair_round
  if only_fixes "$E" "$F"; then fail 'partial preservation counted as the complete reviewed repair'; fi
  echo 'ok: removing part of the reviewed repair requires a full review'
  C=$saved_C; D=$saved_D

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

  # R and S cancel inside the merge, so U reverses only an unrelated file.
  # U's final bug contents match R's parent, but U never undid R. Reverting S
  # afterwards must invalidate D, at both the producer and coverage consumer.
  # Exercise either recorded mainline: no ancestry-only bypass may accept U.
  g checkout -q --detach "$R"
  g revert --no-edit "$R" >/dev/null
  S=$(git rev-parse HEAD)
  cancel_side=$(commit_file 'unrelated change beside cancelling reverts' side cancel-side)
  for mainline in 1 2; do
    g checkout -q --detach "$D"
    g commit -q --allow-empty -m "retained mainline $mainline"
    retained=$(git rev-parse HEAD)
    if [ "$mainline" = 1 ]; then
      g merge -q --no-ff -m 'merge cancelling reverts and unrelated change' "$cancel_side"
    else
      g checkout -q --detach "$cancel_side"
      g merge -q --no-ff -m 'merge with cancelling reverts on parent 1' "$retained"
    fi
    cancelled_merge=$(git rev-parse HEAD)
    g revert --no-edit -m "$mainline" "$cancelled_merge" >/dev/null
    U=$(git rev-parse HEAD)
    git diff --quiet "$U^" "$U" -- bug || fail 'cancellation fixture changed the bug in U'
    git diff --exit-code "$D" "$U" || fail 'cancellation fixture did not restore D tree'
    repair_round "$D"
    only_fixes "$E" "$F" || fail 'cancelled reverts invalidated the standing repair'
    run 4 "review $F" success skipped "$E" tests-only-fix
    RP "$F" o/r "$P" || fail "standing repair lost deployment coverage: $(cat "$T/err")"

    g checkout -q --detach "$U"
    g revert --no-edit "$S" >/dev/null
    [ "$(cat bug)" = broken ] || fail 'cancellation fixture did not restore the blocked bug'
    repair_round "$D"
    bad=0
    if only_fixes "$E" "$F"; then
      echo "FAIL: mainline $mainline unrelated merge undo cancelled R and approved tests-only" >&2
      bad=1
    fi
    run 4 "review $F" success skipped "$E" tests-only-fix
    if RP "$F" o/r "$P"; then
      echo "FAIL: mainline $mainline unrelated merge undo allowed deployment coverage back to production" >&2
      bad=1
    fi
    [ "$bad" = 0 ] || fail 'cancelling constituents forged restoration of a passing repair'
    echo "ok: cancelled constituents cannot forge restoration (mainline $mainline)"
  done

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
