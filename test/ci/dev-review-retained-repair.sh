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
focus=${1:-}
updates=()
approval() { # approval <0: allow, 1: reject> <description>
  local expected=$1 description=$2 b e f actual update base coverage_base id=10
  b=$(git rev-parse HEAD)
  e=$(commit_file 'later blocked change' broken later)
  f=$(commit_file 'repair later change' fixed later)
  g commit -q --amend -m 'repair later change' -m "Review-Fix-Of: $e"
  f=$(git rev-parse HEAD)
  reset
  run 1 "review $C" success failure "$P" '' blocked
  run 2 "review $D" success success "$P"
  printf 'review-range: %s %s\n' "$P" "$D" > "$FX/log-1002.txt"
  base=$D
  for update in "${updates[@]}"; do
    run "$id" "review $update" success success "$base"
    printf 'review-range: %s %s\n' "$base" "$update" > "$FX/log-$((id + 1000)).txt"
    base=$update; id=$((id + 1))
  done
  coverage_base=$base
  case "${3:-}" in
    gap)
      base=$(git rev-parse "$base^1")
      jq --arg b "$base" '.base = $b' "$FX/attest-$((id - 1)).json" > "$FX/gap.json"
      mv "$FX/gap.json" "$FX/attest-$((id - 1)).json"
      printf 'review-range: %s %s\n' "$base" "${updates[-1]}" > "$FX/log-$((id + 999)).txt"
      ;;
    missing-proof) rm "$FX/attest-$((id - 1)).json" ;;
    crash)
      jq '.jobs[1].steps[0].conclusion = "failure"' "$FX/jobs-$((id - 1)).json" > "$FX/crash.json"
      mv "$FX/crash.json" "$FX/jobs-$((id - 1)).json"
      ;;
  esac
  run 3 "review $e" success failure "$coverage_base" '' blocked
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
  # Keep the focused before/after proof short once both consumers disagree.
  if [ "$focus" = --reviewed-updates ] && [ "$bad" != 0 ]; then fail "$description"; fi
  g checkout -q --detach "$b"
}
P=$(commit_file production good bug)
git update-ref refs/remotes/origin/main "$P"
C=$(commit_file 'blocked bug' $'broken\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12' bug)
if [ "${1:-}" != --reviewed-updates ]; then
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

# Preservation follows the approved net state, including constituents cancelled
# before D's review. Q retains X independently; undoing M resurrects X, and
# undoing that undo restores D exactly. X must not then be required at head.
for cancellation in full partial; do
  g checkout -q --detach "$C"
  printf 'temporary\n' > transient
  printf 'retained\n' > lasting
  g add transient lasting; g commit -q -m 'temporary and lasting constituents before review'
  X=$(git rev-parse HEAD)
  if [ "$cancellation" = full ]; then
    g revert --no-edit "$X" >/dev/null
  else
    g rm -q transient
    g commit -q -m 'cancel only the transient part before review'
  fi
  D=$(commit_file 'passing repair after cancellation' $'good\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12' bug)
  for mainline in 1 2; do
    g checkout -q --detach "$C"
    g cherry-pick "$X" >/dev/null
    g commit -q --amend -m 'independent temporary patch on retained mainline'
    Q=$(git rev-parse HEAD)
    if git merge-base --is-ancestor "$Q" "$D"; then fail 'Q must be outside the reviewed ancestry'; fi
    if [ "$mainline" = 2 ]; then g checkout -q --detach "$D"; side=$Q; else side=$D; fi
    g merge -q --no-ff --no-commit "$side"
    # The approved merge resolution cancels Q's transient addition too.
    g read-tree --reset -u "$D"
    g commit -q -m 'merge with the exact approved net tree'
    M=$(git rev-parse HEAD)
    git diff --exit-code "$D" "$M" || fail 'merge did not resolve to the reviewed tree'
    g revert --no-edit -m "$mainline" "$M" >/dev/null
    U=$(git rev-parse HEAD)
    [ -f transient ] || fail 'merge undo did not resurrect the cancelled constituent'
    approval 1 "$cancellation cancellation, mainline $mainline cancelled constituent resurrected and repair removed"

    g revert --no-edit "$U" >/dev/null
    V=$(git rev-parse HEAD)
    git diff --exit-code "$D" "$V" || fail 'undoing the undo did not restore the reviewed tree'
    approval 0 "$cancellation cancellation, mainline $mainline approved cancellation restored exactly"

    # Exact tree equality is not the rule: independent hunks may differ at head.
    printf 'candidate metadata\n' >> bug
    g add bug; g commit -q -m 'unrelated metadata after restoring the approved cancellation'
    approval 0 "$cancellation cancellation, mainline $mainline approved cancellation restored with metadata"

    # Restoring the cancelled constituent again must invalidate D's evidence.
    g revert --no-edit "$V" >/dev/null
    approval 1 "$cancellation cancellation, mainline $mainline restoration reverted again"
    echo "ok: mainline $mainline preserves the approved cancellation through restoration"
  done
done

# The reviewed result can refine a constituent rather than cancel it. U keeps
# A's obsolete patch on its sibling mainline; V restores D's approved result.
# Requiring A at V would reject even the exact tree that passed the review.
g checkout -q --detach "$C"
A=$(commit_file 'initial repair before review' $'fixed\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12' bug)
D=$(commit_file 'reviewed refinement of the initial repair' $'fixed-and-validated\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12' bug)
for mainline in 1 2; do
  g checkout -q --detach "$C"
  g cherry-pick "$A" >/dev/null
  g commit -q --amend -m 'independent initial repair on retained mainline'
  Q=$(git rev-parse HEAD)
  if git merge-base --is-ancestor "$Q" "$D"; then fail 'Q must be outside the reviewed ancestry'; fi
  if [ "$mainline" = 2 ]; then g checkout -q --detach "$D"; side=$Q; else side=$D; fi
  # Both branches changed the same line. Resolve the merge to D's exact tree.
  if g merge -q --no-ff --no-commit "$side"; then fail 'expected competing repair refinements'; fi
  g read-tree --reset -u "$D"
  g commit -q -m 'resolve merge to the reviewed refinement'
  M=$(git rev-parse HEAD)
  git diff --exit-code "$D" "$M" || fail 'merge did not resolve to the reviewed refinement'
  g revert --no-edit -m "$mainline" "$M" >/dev/null
  U=$(git rev-parse HEAD)
  git diff --exit-code "$A" "$U" || fail 'merge undo did not retain the obsolete initial repair'
  approval 1 "refinement, mainline $mainline obsolete initial repair alone"

  g revert --no-edit "$U" >/dev/null
  V=$(git rev-parse HEAD)
  git diff --exit-code "$D" "$V" || fail 'undoing the undo did not restore the reviewed refinement'
  approval 0 "refinement, mainline $mainline approved result restored exactly"

  printf 'candidate metadata\n' >> bug
  g add bug; g commit -q -m 'unrelated metadata after restoring the reviewed refinement'
  approval 0 "refinement, mainline $mainline approved result restored with metadata"

  g revert --no-edit "$V" >/dev/null
  [ "$(head -1 bug)" = fixed ] || fail 'reverting restoration did not remove the reviewed refinement'
  approval 1 "refinement, mainline $mainline restoration reverted again"
  echo "ok: mainline $mainline preserves the reviewed refinement through restoration"
done
fi

# A's reviewed contribution must not freeze D's unrelated config. Also test
# updates to A's own paths: only a continuous, standing review chain may
# replace their approved state. Exercise both producer and approval consumer.
for contribution in separate-path shared-path; do
  g checkout -q --detach "$C"
  A=$(commit_file 'initial repair before config review' good bug)
  if [ "$contribution" = shared-path ]; then
    printf '0\n' > config
    g add config; g commit -q --amend --no-edit
    A=$(git rev-parse HEAD)
  fi
  D=$(commit_file 'reviewed config beside the initial repair' 1 config)
  for mainline in 1 2; do
    updates=()
    g checkout -q --detach "$C"
    g cherry-pick "$A" >/dev/null
    g commit -q --amend -m 'independent initial repair before config review'
    Q=$(git rev-parse HEAD)
    if [ "$mainline" = 2 ]; then g checkout -q --detach "$D"; side=$Q; else side=$D; fi
    if ! g merge -q --no-ff --no-commit "$side"; then
      [ "$contribution" = shared-path ] || fail 'unexpected retained-repair merge conflict'
    fi
    g read-tree --reset -u "$D"
    g commit -q -m 'merge with the exact reviewed repair and config'
    M=$(git rev-parse HEAD)
    g revert --no-edit -m "$mainline" "$M" >/dev/null
    U=$(git rev-parse HEAD)
    g revert --no-edit "$U" >/dev/null
    V=$(git rev-parse HEAD)
    git diff --exit-code "$D" "$V" || fail 'restored tree differs from reviewed D'
    approval 0 "$contribution mainline $mainline exact D restored"

    L=$(commit_file 'separately reviewed config update' 2 config)
    updates=("$L")
    approval 0 "$contribution mainline $mainline later reviewed config update"

    # A second review has its own incremental range, not D..L2.
    L2=$(commit_file 'another separately reviewed config update' 3 config)
    updates+=("$L2")
    approval 0 "$contribution mainline $mainline two linked reviewed updates"

    if ! g revert --no-edit "$Q" >/dev/null; then
      [ "$contribution" = shared-path ] || fail 'unexpected repair removal conflict'
      g checkout --ours -- config
      g add config; g revert --continue >/dev/null
    fi
    [ "$(head -1 bug)" = broken ] || fail 'removing Q did not restore the blocked bug'
    approval 1 "$contribution mainline $mainline reviewed config cannot hide missing repair"

    # A review may refine the repair itself. Its replacement state must stand,
    # and a missing link / review or later removal cannot authorize that state.
    updates=()
    g checkout -q --detach "$V"
    L=$(commit_file 'separately reviewed repair refinement' better bug)
    approval 1 "$contribution mainline $mainline unreviewed replacement repair"
    updates=("$L")
    approval 1 "$contribution mainline $mainline gapped replacement review" gap
    approval 1 "$contribution mainline $mainline replacement without proof" missing-proof
    approval 1 "$contribution mainline $mainline crashed replacement review" crash
    approval 0 "$contribution mainline $mainline later reviewed replacement repair"
    g revert --no-edit "$L" >/dev/null
    approval 0 "$contribution mainline $mainline original approved repair restored"
    if ! g revert --no-edit "$Q" >/dev/null; then
      [ "$contribution" = shared-path ] || fail 'unexpected repair removal conflict'
      g checkout --ours -- config
      g add config; g revert --continue >/dev/null
    fi
    approval 1 "$contribution mainline $mainline reverted later review cannot hide missing repair"
    echo "ok: $contribution mainline $mainline scopes preservation across later reviews"
  done
done
[ "$bad" = 0 ] || fail 'merge-undo preservation disagrees with the approved net state'
