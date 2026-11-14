#!/usr/bin/env bash
# Retained / restored repairs after reverts: every history here has a revert AFTER the passing review D (a merge undo,
# a revert of a revert, a reverted sibling, …). These fixtures were added by thirteen rounds (11-13 17:08Z → 11-14, the
# last d04a520aa: renamed / chained / scoped restorations, and ee438bc0e: composed restorations, blocked-round
# replacements) that tried to prove D's reviewed contribution still stands; each
# re-check found another case the proof got wrong. The rule is now the conservative one (dev-review-base.sh review_stands,
# supervisor 11-14): any revert after D → D does not supersede the blocked C → C's range gets a full review. So every
# fixture with a revert after D expects a full review (1) — the ones that used to expect a tests-only round (restorations, retained
# equivalents, renamed contributions, reviewed replacements) included. Supersession without reverts (liveness):
# dev-review-supersession-reverts.sh and the "control" of blocked_replacement_cases.
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
approval() { # <0: allow, 1: reject> <description> [review failure] [later-round path]
  local expected=$1 description=$2 b e f actual update base coverage_base id=10
  b=$(git rev-parse HEAD)
  e=$(commit_file 'later blocked change' broken "${4:-later}")
  f=$(commit_file 'repair later change' fixed "${4:-later}")
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
  case "$focus" in
    --reviewed-updates|--adopted-sibling-renames)
      [ "$bad" = 0 ] || fail "$description" ;;
  esac
  g checkout -q --detach "$b"
}
P=$(commit_file production good bug)
git update-ref refs/remotes/origin/main "$P"
C=$(commit_file 'blocked bug' $'broken\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12' bug)

# A clean undo can supply only the part not already independently restored.
# It must still complete the contribution, and removing that remainder must
# invalidate approval again. Exercise direct and containing-merge removals.
composed_restoration_cases() {
  local mode R S U retained other M
  g checkout -q --detach "$P"
  printf 'broken-a\n' > a; printf 'broken-b\n' > b
  g add a b; g commit -q -m 'blocked two-file defect'; C=$(git rev-parse HEAD)
  printf 'fixed-a\n' > a; printf 'fixed-b\n' > b
  g add a b; g commit -q -m 'passing two-file repair'; D=$(git rev-parse HEAD)
  for mode in direct 1 2; do
    g checkout -q --detach "$D"
    if [ "$mode" = direct ]; then
      g revert --no-edit "$D" >/dev/null
    else
      g checkout -q --detach "$C"
      g commit -q --allow-empty -m 'independent blocked mainline'
      retained=$(git rev-parse HEAD)
      if [ "$mode" = 2 ]; then g checkout -q --detach "$D"; other=$retained; else other=$D; fi
      g merge -q --no-ff -m 'merge two-file repair' "$other"
      M=$(git rev-parse HEAD)
      g revert --no-edit -m "$mode" "$M" >/dev/null
    fi
    R=$(git rev-parse HEAD)
    S=$(commit_file 'independently restore the first file' fixed-a a)
    approval 1 "$mode independently restored subset is incomplete"
    g revert --no-edit "$R" >/dev/null
    U=$(git rev-parse HEAD)
    git diff --exit-code "$D" "$U" || fail 'composed undo must restore the exact approved tree'
    [ "$(git diff --name-only "$S" "$U")" = b ] || fail 'clean undo must change only the remaining file'
    approval 1 "$mode clean undo completes independent restoration"
    g revert --no-edit "$U" >/dev/null
    approval 1 "$mode completed restoration removed again"
    g revert --no-edit HEAD >/dev/null
    approval 1 "$mode completed restoration reinstated"
  done
  echo 'exercised: composed restoration through both approval consumers'
}

blocked_replacement_cases() {
  local mode variant U Q side M E F H expected actual base description
  for mode in control restored retained; do
    g checkout -q --detach "$P"
    C=$(commit_file 'blocked replacement baseline' broken bug)
    D=$(commit_file 'passing version one repair' fixed-v1 bug)
    if [ "$mode" = restored ]; then
      g revert --no-edit "$D" >/dev/null
      g revert --no-edit HEAD >/dev/null
    elif [ "$mode" = retained ]; then
      side=$(commit_file 'unrelated descendant' side side)
      g checkout -q --detach "$C"
      g cherry-pick "$D" >/dev/null
      g commit -q --amend -m 'independent retained version one'; Q=$(git rev-parse HEAD)
      g merge -q --no-ff -m 'merge review with retained equivalent' "$side"
      M=$(git rev-parse HEAD)
      g revert --no-edit -m 1 "$M" >/dev/null
    fi
    U=$(git rev-parse HEAD)
    # E reviews D..E; its completed blocked verdict plus F is a coverage link.
    # The repair itself refines D, so checking only E's snapshot is too strict.
    E=$(commit_file 'later blocked review' broken later)
    F=$(commit_file 'repair and refine earlier contribution' fixed-v2 bug)
    g commit -q --amend -m 'repair and refine earlier contribution' -m "Review-Fix-Of: $E"
    F=$(git rev-parse HEAD)
    for variant in valid missing-proof crash skipped gap unrepaired; do
      # The control differs only by omission of the net-zero revert pair.
      if [ "$mode" = control ] && [ "$variant" != valid ]; then continue; fi
      g checkout -q --detach "$F"
      H=$F; base=$E; expected=1
      case "$variant" in
        valid) [ "$mode" = control ] && expected=0 ;;   # control: no revert after D → D still supersedes C
        unrepaired)
          g commit -q --amend -m 'refinement without a repair trailer'; H=$(git rev-parse HEAD) ;;
      esac
      reset
      run 1 "review $C" success failure "$P" '' blocked
      run 2 "review $D" success success "$P"
      printf 'review-range: %s %s\n' "$P" "$D" > "$FX/log-1002.txt"
      case "$variant" in
        crash) run 3 "review $E" success failure "$D" ;;
        skipped) run 3 "review $E" success skipped "$D" tests-only-fix ;;
        *) run 3 "review $E" success failure "$D" '' blocked ;;
      esac
      case "$variant" in
        missing-proof) rm "$FX/attest-3.json" ;;
        gap)
          jq --arg b "$U" '.base = $b' "$FX/attest-3.json" > "$FX/gap.json"
          mv "$FX/gap.json" "$FX/attest-3.json" ;;
      esac
      run 4 "review $H" success skipped "$base" tests-only-fix
      description="$mode blocked replacement $variant"
      actual=0; bash "$CI/dev-review-base.sh" --only-fixes "$base" "$H" || actual=$?
      if [ "$actual" != "$expected" ]; then
        echo "FAIL: $description: tests-only gate returned $actual, expected $expected" >&2; bad=1
      fi
      actual=0; RP "$H" o/r "$P" || actual=$?
      if [ "$actual" != "$expected" ]; then
        echo "FAIL: $description: deployment coverage returned $actual, expected $expected" >&2; bad=1
      fi
    done
  done
  echo 'exercised: completed blocked-review replacements and invalid coverage'
}
case "$focus" in
  --composed-restoration) composed_restoration_cases ;;
  --blocked-replacements) blocked_replacement_cases ;;
esac
case "$focus" in
  --composed-restoration|--blocked-replacements)
    [ "$bad" = 0 ] || fail 'composed restoration or completed repair coverage rejected'
    exit 0 ;;
esac

# A sibling renamed old before the blocked C; independent repair X never saw
# that rename. D keeps both paths and refines X in old. The sibling's rename
# must not freeze unrelated when a later merge undo checks X's contribution.
unrelated_rename_cases() {
  local O X renamed side retained other M mainline
  local old=$'broken\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12'
  g checkout -q --detach "$P"
  O=$(commit_file 'old path before independent histories' "$old" old)
  X=$(commit_file 'independent repair of old' "${old/broken/good}" old)
  g checkout -q --detach "$O"
  g mv old unrelated
  g commit -q -m 'unrelated sibling renames old before blocked review'
  renamed=$(git rev-parse HEAD)
  C=$(commit_file 'blocked independent change' broken bug)
  if git merge-base --is-ancestor "$X" "$renamed"; then fail 'sibling rename must not descend from X'; fi
  if ! g merge -q --no-ff --no-commit "$X" >"$T/merge.out" 2>&1; then
    [ -n "$(git ls-files -u)" ] || fail 'unexpected independent repair merge failure'
  fi
  printf '%s\n' "$old" > unrelated
  printf '%s\n' "${old/broken/better}" > old
  printf 'good\n' > bug
  g add -A; g commit -q -m 'passing merge retains sibling file and refines repair in old'
  D=$(git rev-parse HEAD)
  side=$(commit_file 'unrelated descendant side file' side side)
  for mainline in 1 2; do
    updates=()
    g checkout -q --detach "$D"
    approval 0 "sibling rename mainline $mainline reviewed merge intact"
    g commit -q --allow-empty -m 'retained reviewed ancestry'
    retained=$(git rev-parse HEAD)
    if [ "$mainline" = 2 ]; then g checkout -q --detach "$side"; other=$retained; else other=$side; fi
    g merge -q --no-ff -m 'merge unrelated descendant beside reviewed repair' "$other"
    M=$(git rev-parse HEAD)
    g revert --no-edit -m "$mainline" "$M" >/dev/null
    git diff --exit-code "$D" HEAD || fail 'unrelated merge undo must retain exactly D'
    approval 1 "sibling rename mainline $mainline reviewed tree retained after undo"
    commit_file 'edit unrelated sibling rename destination' unrelated-update unrelated >/dev/null
    [ "$(head -1 old)" = better ] || fail 'unrelated edit must retain the reviewed repair'
    approval 1 "sibling rename mainline $mainline unrelated edit preserves reviewed repair"
    commit_file 'remove reviewed repair after unrelated edit' "$old" old >/dev/null
    approval 1 "sibling rename mainline $mainline missing reviewed repair rejected"
  done
  echo 'exercised: sibling rename history stays outside the reviewed contribution'
}
if [ "$focus" = --unrelated-renames ]; then
  unrelated_rename_cases
  [ "$bad" = 0 ] || fail 'unrelated rename history contaminated the reviewed contribution'
  exit 0
fi

# A sibling can supply the rename that D actually adopts. Refinement on
# that sibling makes the rename invisible in D's diff against X; its earlier
# rename edges connected X to the destination in the retired proof. Any
# revert after D now requires a full review, including restoration of the repair.
adopted_sibling_rename_cases() {
  local O X renamed side retained other M mainline mode file removed
  local old=$'broken\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12'
  local refined=$'broken\nalpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\nkappa'
  for mode in refined chained; do
    g checkout -q --detach "$P"
    O=$(commit_file 'original path before sibling histories' "$old" old)
    X=$(commit_file 'independent repair before adopted rename' "${old/broken/good}" old)
    side=$(commit_file 'unreviewed sibling descended from repair' side side)
    g checkout -q --detach "$O"
    g mv old 'middle name'
    g commit -q -m 'sibling renames original path'
    file='middle name'
    commit_file 'sibling extensively refines renamed file' "$refined" "$file" >/dev/null
    if [ "$mode" = chained ]; then
      g mv "$file" $'new\nname'
      g commit -q -m 'sibling renames refined file again'
      file=$'new\nname'
    fi
    renamed=$(git rev-parse HEAD)
    C=$(commit_file 'blocked change after sibling rename and refinement' broken bug)
    if git merge-base --is-ancestor "$X" "$renamed"; then fail 'adopted sibling must not descend from X'; fi
    if ! g merge -q --no-ff --no-commit "$X" >"$T/merge.out" 2>&1; then
      [ -n "$(git ls-files -u)" ] || fail 'unexpected adopted rename merge failure'
    fi
    g rm -q -f --ignore-unmatch old
    printf '%s\n' "${refined/broken/better}" > "$file"
    printf 'good\n' > bug
    g add -A; g commit -q -m 'passing merge adopts sibling rename and refines independent repair'
    D=$(git rev-parse HEAD)
    [ -z "$(git diff --name-only --diff-filter=R --find-renames=50% "$X" "$D")" ] ||
      fail 'fixture must require sibling history to recover the adopted rename'
    for mainline in 1 2; do
      updates=()
      g checkout -q --detach "$D"
      approval 0 "$mode adopted sibling mainline $mainline reviewed merge intact"
      g checkout -q --detach "$X"
      g commit -q --allow-empty -m 'retained repair on unreviewed sibling'
      retained=$(git rev-parse HEAD)
      if [ "$mainline" = 2 ]; then g checkout -q --detach "$side"; other=$retained; else other=$side; fi
      g merge -q --no-ff -m 'merge unreviewed sibling descended from repair' "$other"
      M=$(git rev-parse HEAD)
      if git merge-base --is-ancestor "$D" "$M"; then fail 'unreviewed sibling merge must not contain D'; fi
      g checkout -q --detach "$D"
      g merge -q --no-ff -m 'bring unreviewed sibling beside adopted repair' "$M"
      g revert --no-edit -m "$mainline" "$M" >/dev/null
      git diff --exit-code "$D" HEAD || fail 'sibling merge undo must retain exactly D'
      removed=$(commit_file 'remove repair from adopted sibling destination' "$refined" "$file")
      approval 1 "$mode adopted sibling mainline $mainline missing repair rejected"
      g revert --no-edit "$removed" >/dev/null
      approval 1 "$mode adopted sibling mainline $mainline restored repair still needs full review"
    done
  done
  echo 'exercised: adopted sibling rename lineage through both approval consumers'
}
if [ "$focus" = --adopted-sibling-renames ]; then
  adopted_sibling_rename_cases
  [ "$bad" = 0 ] || fail 'adopted sibling rename lost the reviewed contribution'
  exit 0
fi

# A reviewed rename/refinement remains the same contribution. Shared ancestry
# must still be checked when only an unrelated descendant is merged and undone.
rename_cases() {
  local X side other M retained mainline mode L file old=$'old\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12'
  for mode in plain refined chained; do
    g checkout -q --detach "$P"
    C=$(commit_file 'blocked old filename' "$old" old)
    X=$(commit_file 'initial repair on old filename' "${old/old/good}" old)
    g mv old 'middle name'
    if [ "$mode" != plain ]; then printf '%s\n' "${old/old/better}" > 'middle name'; fi
    g add -A; g commit -q -m 'reviewed rename and refinement'
    if [ "$mode" = chained ]; then
      g mv 'middle name' $'new\nname'
      printf '%s\n' "${old/old/best}" > $'new\nname'
      g add -A; g commit -q -m 'second reviewed rename and refinement'
      file=$'new\nname'
    else file='middle name'; fi
    D=$(git rev-parse HEAD)
    side=$(commit_file 'unrelated descendant side file' side side)
    for mainline in 1 2; do
      updates=()
      g checkout -q --detach "$D"
      g commit -q --allow-empty -m 'retained reviewed ancestry'
      retained=$(git rev-parse HEAD)
      if [ "$mainline" = 2 ]; then g checkout -q --detach "$side"; other=$retained; else other=$side; fi
      g merge -q --no-ff -m 'merge unrelated descendant with shared review' "$other"
      M=$(git rev-parse HEAD)
      g revert --no-edit -m "$mainline" "$M" >/dev/null
      git diff --exit-code "$D" HEAD || fail 'shared rename undo must retain exactly D'
      approval 1 "$mode rename mainline $mainline complete reviewed tree retained"

      L=$(commit_file 'separately reviewed renamed repair update' "${old/old/newer}" "$file")
      g mv "$file" replacement
      g commit -q -m 'later separately reviewed rename'; L=$(git rev-parse HEAD)
      approval 1 "$mode rename mainline $mainline unreviewed replacement"
      updates=("$L")
      approval 1 "$mode rename mainline $mainline replacement lacks proof" missing-proof
      approval 1 "$mode rename mainline $mainline reviewed replacement follows rename"
      updates=()

      g checkout -q --detach "$D"
      g commit -q --allow-empty -m 'another retained reviewed ancestry'
      retained=$(git rev-parse HEAD)
      if [ "$mainline" = 2 ]; then g checkout -q --detach "$side"; other=$retained; else other=$side; fi
      g merge -q --no-ff -m 'merge unrelated descendant before repair removal' "$other"
      g revert --no-edit -m "$mainline" HEAD >/dev/null
      commit_file 'remove repair at renamed destination' "$old" "$file" >/dev/null
      approval 1 "$mode rename mainline $mainline removed renamed contribution"
      # Keeping the old patch at its historical name cannot replace D's
      # refined destination (the plain rename still preserves the same patch).
      if [ "$mode" != plain ]; then
        commit_file 'obsolete repair at original name' "${old/old/good}" old >/dev/null
        approval 1 "$mode rename mainline $mainline obsolete original cannot hide removal"
      fi
    done
  done
  echo 'ok: reviewed contributions follow rename lineage at both approval consumers'
}

# A merge undo removes the reviewed repair and an unreviewed side change. A
# conflict-resolved direct undo may restore only the approved contribution.
scoped_restoration_cases() {
  local mainline unrelated repair file side retained other M R V broken=$'broken\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12'
  for repair in plain renamed; do
    for unrelated in separate-file same-file; do
      if [ "$repair" = renamed ] && [ "$unrelated" = same-file ]; then continue; fi
      file=bug
      g checkout -q --detach "$P"
      C=$(commit_file 'blocked contextual repair' "$broken" bug)
      D=$(commit_file 'passing contextual repair' "${broken/broken/good}" bug)
      if [ "$repair" = renamed ]; then
        g mv bug reviewed
        file=reviewed
        printf '%s\n' "${broken/broken/better}" > "$file"
        g add -A; g commit -q -m 'reviewed contextual rename and refinement'
        D=$(git rev-parse HEAD)
      fi
      if [ "$unrelated" = separate-file ]; then
        side=$(commit_file 'unreviewed descendant side change' side side)
      else
        side=$(commit_file 'unreviewed descendant side hunk' "${broken/broken/good}"$'\nside' bug)
      fi
      for mainline in 1 2; do
        updates=()
        g checkout -q --detach "$C"
        g commit -q --allow-empty -m 'independent blocked mainline'
        retained=$(git rev-parse HEAD)
        if [ "$mainline" = 2 ]; then g checkout -q --detach "$side"; other=$retained; else other=$side; fi
        g merge -q --no-ff -m 'merge repair and unreviewed descendant' "$other"
        M=$(git rev-parse HEAD)
        g revert --no-edit -m "$mainline" "$M" >/dev/null
        R=$(git rev-parse HEAD)
        approval 1 "$repair $unrelated mainline $mainline contextual repair removed"
        if [ "$unrelated" = separate-file ]; then
          commit_file 'divergent unreviewed side change' diverged side >/dev/null
        else
          commit_file 'divergent unreviewed side hunk' "$broken"$'\ndiverged' bug >/dev/null
        fi
        if g revert --no-edit "$R" >"$T/revert.out" 2>&1; then fail 'expected contextual direct undo conflict'; fi
        [ -n "$(git ls-files -u)" ] || fail 'contextual undo did not conflict'
        if [ "$repair" = renamed ]; then
          g rm -q --ignore-unmatch bug
          printf '%s\n' "${broken/broken/better}" > "$file"
        else
          printf '%s\n' "${broken/broken/good}" > "$file"
        fi
        if [ "$unrelated" = separate-file ]; then g rm -q -f side; fi
        g add "$file"; g revert --continue >/dev/null
        V=$(git rev-parse HEAD)
        git diff --exit-code "$D" HEAD || fail 'contextual undo must restore exactly D'
        approval 1 "$repair $unrelated mainline $mainline only approved contribution restored"
        g revert --no-edit "$V" >/dev/null
        approval 1 "$repair $unrelated mainline $mainline scoped restoration removed again"
        g revert --no-edit HEAD >/dev/null
        git diff --exit-code "$D" HEAD || fail 'second contextual undo must restore D'
        approval 1 "$repair $unrelated mainline $mainline scoped restoration restored again"
      done
    done
  done
  echo 'ok: restoration requires the reviewed contribution without unreviewed side changes'
}
case "$focus" in
  --renames) rename_cases ;;
  --scoped-restoration) scoped_restoration_cases ;;
esac
case "$focus" in
  --renames|--scoped-restoration)
    [ "$bad" = 0 ] || fail 'reviewed contribution context was lost'
    exit 0 ;;
esac

# Submodules (gitlinks, ignore=all) and forced diff coloring used to be able to fool the patch proofs; with no content
# proofs left, these histories (each with a revert after D) simply get a full review.
proof_input_cases() {
  local kind=$1 mainline A Q side other M U removed s0 s1 s2 mode path
  for mode in tracked configured; do
    g checkout -q --detach "$P"
    if [ "$kind" = submodule ]; then
      s0=$P
      printf '[submodule "module"]\n\tpath = module\n\turl = ./unused\n' > .gitmodules
      if [ "$mode" = tracked ]; then
        printf '\tignore = all\n' >> .gitmodules
      else
        git config submodule.module.ignore all
      fi
      # Real gitlink tree entries; no clone, transport, or initialized checkout.
      git update-index --add --cacheinfo "160000,$s0,module"
      g add .gitmodules; g commit -q -m 'blocked submodule baseline'
      C=$(git rev-parse HEAD); s1=$C
      git update-index --cacheinfo "160000,$s1,module"
      g commit -q -m 'initial submodule repair'; A=$(git rev-parse HEAD); s2=$A
      git update-index --cacheinfo "160000,$s2,module"
      g commit -q -m 'reviewed submodule refinement'; D=$(git rev-parse HEAD)
      git config diff.submodule log
    else
      C=$(commit_file 'blocked colored proof baseline' broken bug)
      A=$(commit_file 'initial repair for colored proof' fixed bug)
      D=$(commit_file 'reviewed refinement for colored proof' better bug)
      git config color.ui always
    fi
    side=$(commit_file 'unrelated file beside refinement' side side)
    for mainline in 1 2; do
      g checkout -q --detach "$C"
      g cherry-pick "$A" >/dev/null
      g commit -q --amend -m 'independent initial repair for proof input'
      Q=$(git rev-parse HEAD)
      if [ "$mainline" = 2 ]; then g checkout -q --detach "$side"; other=$Q; else other=$side; fi
      if ! g merge -q --no-ff --no-commit "$other" >"$T/merge.out" 2>&1; then
        [ -n "$(git ls-files -u)" ] || fail 'expected only a refinement conflict'
      fi
      g read-tree --reset -u "$side"
      g commit -q -m 'resolve to reviewed refinement with unrelated file'
      M=$(git rev-parse HEAD)
      g revert --no-edit -m "$mainline" "$M" >/dev/null
      U=$(git rev-parse HEAD)
      approval 1 "$kind $mode mainline $mainline obsolete initial repair"
      g revert --no-edit "$U" >/dev/null
      approval 1 "$kind $mode mainline $mainline reviewed refinement restored"
      # The removal of Q conflicts with D's refinement. Resolve to the blocked
      # state, retaining Git's genuine revert message for the equivalent repair.
      if g revert --no-edit "$Q" >"$T/revert.out" 2>&1; then fail 'expected refinement removal conflict'; fi
      if [ "$kind" = submodule ]; then
        git update-index --cacheinfo "160000,$s0,module"
      else
        printf 'broken\n' > bug; g add bug
      fi
      g revert --continue >/dev/null
      removed=$(git rev-parse HEAD)
      git diff --quiet --ignore-submodules=none "$C" HEAD -- bug module || fail 'candidate must contain the blocked state'
      approval 1 "$kind $mode mainline $mainline removed equivalent repair"
      g revert --no-edit "$removed" >/dev/null
      approval 1 "$kind $mode mainline $mainline equivalent repair restored again"

      if [ "$kind" = submodule ]; then
        # A direct undo must recognize a nonempty gitlink delta despite ignore.
        g checkout -q --detach "$D"
        g revert --no-edit "$D" >/dev/null
        U=$(git rev-parse HEAD)
        approval 1 "$kind $mode direct revert of refinement"
        g revert --no-edit "$U" >/dev/null
        approval 1 "$kind $mode direct restoration of refinement"
      fi
    done
    git config --unset-all color.ui || true
    git config --unset-all diff.submodule || true
    git config --unset-all submodule.module.ignore || true
    echo "exercised: $kind $mode proof inputs"
    [ "$kind" = submodule ] || break
  done
}

# Y is shared with the retained merge mainline. The merge's first-parent
# patch contains only A, so proving introduced constituents misses Y entirely.
shared_contribution_cases() {
  local A Y Z Q side other M removed mainline sharing
  g checkout -q --detach "$P"
  printf 'broken\n' > bug; printf 'broken\n' > extra
  g add bug extra; g commit -q -m 'blocked two independent defects'
  C=$(git rev-parse HEAD)
  A=$(commit_file 'independent bug repair' good bug)
  g checkout -q --detach "$C"
  Y=$(commit_file 'independent extra repair' good extra)
  g merge -q --no-ff -m 'passing review merges both repairs' "$A"
  D=$(git rev-parse HEAD)
  side=$(commit_file 'unrelated descendant of passing review' side side)
  for sharing in one all; do
    for mainline in 1 2; do
      updates=()
      g checkout -q --detach "$C"
      g cherry-pick "$Y" >/dev/null
      g commit -q --amend -m 'equivalent extra repair on retained mainline'
      Z=$(git rev-parse HEAD)
      g merge -q --no-ff -m 'share original extra repair ancestry' "$Y"
      if [ "$sharing" = all ]; then
        g merge -q --no-ff -m 'share the complete passing review ancestry' "$D"
      else
        g cherry-pick "$A" >/dev/null
        g commit -q --amend -m 'equivalent bug repair on retained mainline'
      fi
      Q=$(git rev-parse HEAD)
      if [ "$mainline" = 2 ]; then g checkout -q --detach "$side"; other=$Q; else other=$side; fi
      g merge -q --no-ff -m 'merge reviewed descendant beside shared repair' "$other"
      M=$(git rev-parse HEAD)
      g revert --no-edit -m "$mainline" "$M" >/dev/null
      git diff --quiet --ignore-submodules=none "$D" HEAD || fail 'merge undo must retain exactly the reviewed tree'
      approval 1 "shared $sharing mainline $mainline complete reviewed tree retained"
      g revert --no-edit "$Z" >/dev/null
      removed=$(git rev-parse HEAD)
      [ "$(cat bug)" = good ] && [ "$(cat extra)" = broken ] || fail 'shared repair removal fixture is wrong'
      approval 1 "shared $sharing mainline $mainline equivalent of shared repair removed"
      g revert --no-edit "$removed" >/dev/null
      approval 1 "shared $sharing mainline $mainline shared repair restored"
      updates=("$(commit_file 'later reviewed shared repair refinement' better extra)")
      approval 1 "shared $sharing mainline $mainline independently reviewed replacement"
    done
  done
  echo 'exercised: shared reviewed contributions through candidate head'
}
case "$focus" in
  --submodules) proof_input_cases submodule ;;
  --color) proof_input_cases color ;;
  --shared-contributions) shared_contribution_cases ;;
esac
case "$focus" in
  --submodules|--color|--shared-contributions)
    [ "$bad" = 0 ] || fail 'retained-contribution proof bypassed by candidate inputs or shared ancestry'
    exit 0 ;;
esac

# Keep a retained feature distinct from the repair: its survival cannot vouch
# for a partial undo, a restoration discarded by a merge, or a missed undo.
restoration_cases() {
  local mainline original_C=$C X Q side M U V N retained merged L
  local broken=$'broken-b\nbroken-c' fixed=$'good-b\ngood-c'
  g checkout -q --detach "$P"
  C=$(commit_file 'blocked two-line defect' "$broken" bug)
  X=$(commit_file 'feature before the repair' present feature)
  D=$(commit_file 'passing complete two-line repair' "$fixed" bug)
  for mainline in 1 2; do
    updates=()
    g checkout -q --detach "$C"
    g cherry-pick "$X" >/dev/null
    g commit -q --amend -m 'independently retained feature'
    Q=$(git rev-parse HEAD)
    if [ "$mainline" = 2 ]; then g checkout -q --detach "$D"; side=$Q; else side=$D; fi
    g merge -q --no-ff -m 'merge the reviewed repair beside the retained feature' "$side"
    M=$(git rev-parse HEAD)
    g revert --no-edit -m "$mainline" "$M" >/dev/null
    U=$(git rev-parse HEAD)
    git diff --exit-code "$Q" "$U" || fail 'undo must restore the independently retained feature'

    # #1/#2: use Git's genuine revert conflict, retaining only half the fix.
    commit_file 'divergence before the direct undo' $'diverged-b\nbroken-c' bug >/dev/null
    if g revert --no-edit "$U" >"$T/revert.out" 2>&1; then fail 'expected a direct undo conflict'; fi
    [ -n "$(git ls-files -u -- bug)" ] || fail 'direct undo did not conflict in bug'
    printf 'good-b\nbroken-c\n' > bug
    g add bug; g revert --continue >/dev/null
    approval 1 "#1/#2 mainline $mainline partial direct restoration"

    g checkout -q --detach "$U"
    g revert --no-edit "$U" >/dev/null
    approval 1 "mainline $mainline complete direct restoration"

    g checkout -q --detach "$U"
    commit_file 'conflict before complete restoration' $'diverged-b\nbroken-c' bug >/dev/null
    if g revert --no-edit "$U" >"$T/revert.out" 2>&1; then fail 'expected complete restoration conflict'; fi
    [ -n "$(git ls-files -u -- bug)" ] || fail 'complete restoration did not conflict'
    printf '%s\n' "$fixed" > bug
    g add bug; g revert --continue >/dev/null
    git diff --exit-code "$D" HEAD || fail 'resolved undo must restore exact approved tree'
    approval 0 "mainline $mainline conflict resolved complete restoration"


    # Restore U by undoing a merge which introduced it from the other parent.
    g checkout -q --detach "$D"
    retained=$(commit_file 'retained restoration branch' present restoration-side)
    if [ "$mainline" = 2 ]; then g checkout -q --detach "$U"; side=$retained; else side=$U; fi
    g merge -q --no-ff -m 'merge the repair undo' "$side"
    N=$(git rev-parse HEAD)
    g revert --no-edit -m "$mainline" "$N" >/dev/null
    V=$(git rev-parse HEAD)
    [ "$(cat bug)" = "$fixed" ] || fail 'merge undo did not restore both defect lines'
    approval 1 "mainline $mainline complete merge restoration"

    # #3: reachability of V is insufficient after a conflict resolution drops it.
    g checkout -q --detach "$U"
    commit_file 'competing broken resolution' $'worse-b\nbroken-c' bug >/dev/null
    if g merge -q --no-ff --no-commit "$V" >"$T/merge.out" 2>&1; then fail 'expected competing restoration conflict'; fi
    [ -n "$(git ls-files -u -- bug)" ] || fail 'restoration discard did not conflict in bug'
    printf '%s\n' "$broken" > bug
    g add bug; g commit -q -m 'discard the repair while merging its restoration'
    approval 1 "#3 mainline $mainline merge discards restoration"

    # A separate full review can replace the old repair after restoration.
    g checkout -q --detach "$V"
    L=$(commit_file 'separately reviewed replacement repair' $'better-b\nbetter-c' bug)
    approval 1 "mainline $mainline unreviewed replacement of restored repair"
    updates=("$L")
    approval 1 "mainline $mainline replacement lacks attestation" missing-proof
    approval 1 "mainline $mainline reviewed replacement of restored repair"
    updates=()

    # #4: adjacent metadata makes the endpoint proof for undoing V conflict.
    # Its omission must never authorize the broken candidate after this revert.
    g checkout -q --detach "$U"
    commit_file 'adjacent metadata beside the broken repair' "$broken"$'\nmetadata' bug >/dev/null
    if g merge -q --no-ff --no-commit "$V" >"$T/merge.out" 2>&1; then fail 'expected adjacent metadata conflict'; fi
    [ -n "$(git ls-files -u -- bug)" ] || fail 'adjacent merge did not conflict in bug'
    printf '%s\nmetadata\n' "$fixed" > bug
    g add bug; g commit -q -m 'restore repair and retain adjacent metadata'
    merged=$(git rev-parse HEAD)
    approval 1 "mainline $mainline ambiguous adjacent restoration requires review"
    updates=("$merged")
    approval 1 "mainline $mainline independently reviewed adjacent restoration"
    updates=()
    g revert --no-edit -m 1 "$merged" >/dev/null
    [ "$(cat bug)" = "$broken"$'\nmetadata' ] || fail 'merge undo did not remove the repair beside metadata'
    approval 1 "#4 mainline $mainline adjacent metadata hides later undo"
    updates=("$merged")
    approval 1 "#4 mainline $mainline reverted reviewed restoration cannot restore eligibility"
    updates=()
    echo "ok: restoration provenance and survival exercised for mainline $mainline"
  done
  C=$original_C
}
if [ "$focus" = --restoration ]; then
  restoration_cases
  [ "$bad" = 0 ] || fail 'restoration proof approved a missing repair or rejected a reviewed replacement'
  exit 0
fi

if [ -z "$focus" ]; then
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
  approval 1 "mainline $mainline retained repair"

  # Unrelated same-file changes at the candidate cannot invalidate the patch.
  printf 'candidate metadata\n' >> bug
  g add bug; g commit -q -m 'unrelated same-file change after the merge undo'
  approval 1 "mainline $mainline retained repair with later metadata"

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
  approval 1 "mainline $mainline equivalent repair restored at candidate"
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
    approval 1 "$cancellation cancellation, mainline $mainline approved cancellation restored exactly"

    # Exact tree equality is not the rule: independent hunks may differ at head.
    printf 'candidate metadata\n' >> bug
    g add bug; g commit -q -m 'unrelated metadata after restoring the approved cancellation'
    approval 1 "$cancellation cancellation, mainline $mainline approved cancellation restored with metadata"

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
  approval 1 "refinement, mainline $mainline approved result restored exactly"

  printf 'candidate metadata\n' >> bug
  g add bug; g commit -q -m 'unrelated metadata after restoring the reviewed refinement'
  approval 1 "refinement, mainline $mainline approved result restored with metadata"

  g revert --no-edit "$V" >/dev/null
  [ "$(head -1 bug)" = fixed ] || fail 'reverting restoration did not remove the reviewed refinement'
  approval 1 "refinement, mainline $mainline restoration reverted again"
  echo "ok: mainline $mainline preserves the reviewed refinement through restoration"
done
fi

if [ "$focus" != --reviewed-feature ]; then
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
    approval 1 "$contribution mainline $mainline exact D restored"

    L=$(commit_file 'separately reviewed config update' 2 config)
    updates=("$L")
    approval 1 "$contribution mainline $mainline later reviewed config update"

    # A second review has its own incremental range, not D..L2.
    L2=$(commit_file 'another separately reviewed config update' 3 config)
    updates+=("$L2")
    approval 1 "$contribution mainline $mainline two linked reviewed updates"

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
    approval 1 "$contribution mainline $mainline later reviewed replacement repair"
    g revert --no-edit "$L" >/dev/null
    approval 1 "$contribution mainline $mainline original approved repair restored"
    if ! g revert --no-edit "$Q" >/dev/null; then
      [ "$contribution" = shared-path ] || fail 'unexpected repair removal conflict'
      g checkout --ours -- config
      g add config; g revert --continue >/dev/null
    fi
    approval 1 "$contribution mainline $mainline reverted later review cannot hide missing repair"
    echo "ok: $contribution mainline $mainline scopes preservation across later reviews"
  done
done
fi

# A retained constituent may add a feature while D repairs C and changes another
# path. A later full review may update that other path without freezing D's
# version. Keep the later blocked/repair round on its own path.
g checkout -q --detach "$C"
X=$(commit_file 'feature before the passing repair' feature-present feature)
printf 'good\n' > bug
printf 'version-one\n' > later
g add bug later; g commit -q -m 'passing repair and unrelated initial version'
D=$(git rev-parse HEAD)
for mainline in 1 2; do
  updates=()
  g checkout -q --detach "$C"
  g cherry-pick "$X" >/dev/null
  g commit -q --amend -m 'independent feature on retained mainline'
  Q=$(git rev-parse HEAD)
  if git merge-base --is-ancestor "$Q" "$D"; then fail 'Q must be outside the reviewed ancestry'; fi
  if [ "$mainline" = 2 ]; then g checkout -q --detach "$D"; side=$Q; else side=$D; fi
  g merge -q --no-ff -m 'merge the passing repair into the independent feature' "$side"
  M=$(git rev-parse HEAD)
  g revert --no-edit -m "$mainline" "$M" >/dev/null
  U=$(git rev-parse HEAD)
  g revert --no-edit "$U" >/dev/null
  git diff --exit-code "$D" HEAD || fail 'reverting the undo did not restore D exactly'
  approval 1 "feature mainline $mainline exact D restored" '' later-round

  Z=$(commit_file 'separately reviewed unrelated version update' version-two later)
  updates=("$Z")
  approval 1 "feature mainline $mainline independently reviewed version-two survives" '' later-round
  [ "$(cat bug)" = good ] || fail 'fixture lost the passing repair'
  [ "$(cat feature)" = feature-present ] || fail 'fixture lost the retained feature'
  [ "$(cat later)" = version-two ] || fail 'repair round overwrote the reviewed update'
  if [ "$bad" = 0 ]; then
    echo "ok: feature mainline $mainline accepts the independently reviewed unrelated update"
  fi
done
if [ -z "$focus" ]; then
  restoration_cases
  proof_input_cases submodule
  proof_input_cases color
  shared_contribution_cases
  rename_cases
  unrelated_rename_cases
  adopted_sibling_rename_cases
  scoped_restoration_cases
  composed_restoration_cases
  blocked_replacement_cases
fi
[ "$bad" = 0 ] || fail 'merge-undo preservation disagrees with the approved net state'
