#!/usr/bin/env bash
# Supersession after reverts — the whole class (supervisor 11-14). A blocked dev review C is superseded by a later passing
# review D that re-reviewed C's range, so a later repair round can be tests-only. Since 11-13 17:08Z eleven rounds tried to
# prove that D's reviewed contribution still stands after reverts in D..head (restoration by revert-of-revert, merge undos,
# retained equivalents, refinements, path projections); each re-check found a new history the proof got wrong — the last
# one (dev review of 0cd95ca42, findings #1/#2 on 341cca4e9): a rename inside the passing review, a sibling retaining the
# repaired contents at both paths, merge / undo / redo, then reverting the sibling removed both. The rule is now the
# conservative one: ANY revert in D..head → no supersession → C's range gets a full review (never a tests-only round).
# This matrix: renames (R100 and R<100), copy, delete+add, mode change — each reviewed without a revert (supersession holds:
# liveness), each reverted directly, reverted and restored, merged and undone, undone and redone (full review); the exact
# 0cd95ca42 reproduction; reverts arriving through a side branch or main; a revert inside C..D (reviewed by D: holds); a
# message that only mentions a revert (holds). Both consumers: dev-review-base.sh --only-fixes and review-passed.sh.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
. "$(dirname "$0")/../../scripts/ci/test-review-fixtures.sh"
commit_file() { mkdir -p "$(dirname "$3")"; printf '%s\n' "$2" > "$3"; g add -A "$3"; g commit -q -m "$1"; git rev-parse HEAD; }
bad=0
approval() { # <0: tests-only allowed, 1: full review> <description> — E (blocked) + F (its repair) on top of HEAD
  local expected=$1 description=$2 b e f actual
  b=$(git rev-parse HEAD)
  e=$(commit_file 'later blocked change' broken later)
  f=$(commit_file 'repair later change' fixed later)
  g commit -q --amend -m 'repair later change' -m "Review-Fix-Of: $e"; f=$(git rev-parse HEAD)
  reset
  run 1 "review $C" success failure "$P" '' blocked
  run 2 "review $D" success success "$P"; printf 'review-range: %s %s\n' "$P" "$D" > "$FX/log-1002.txt"
  run 3 "review $e" success failure "$D" '' blocked
  actual=0; bash "$CI/dev-review-base.sh" --only-fixes "$e" "$f" 2>/dev/null || actual=$?
  [ "$actual" = "$expected" ] || { echo "FAIL: $description: --only-fixes returned $actual, expected $expected" >&2; bad=1; }
  run 4 "review $f" success skipped "$e" tests-only-fix
  actual=0; RP "$f" o/r "$P" || actual=$?
  [ "$actual" = "$expected" ] || { echo "FAIL: $description: review-passed.sh returned $actual, expected $expected" >&2; bad=1; }
  g checkout -q --detach "$b"
}
P=$(commit_file production good-a old)
git update-ref refs/remotes/origin/main "$P"
C=$(commit_file 'blocked: breaks old' broken-a old)
D=$(commit_file 'passing repair of old' $'good-a\nrepaired' old)

# Exact 216bed0b9 #1 history: D adopts X's repair through a heavily rewritten
# sibling rename. An undone side merge contains X but not D. The former
# ancestry filter missed the destination and accepted removal of the repair.
# Current main requires a full review after that undo, with or without the
# repair; a fresh complete review restores eligibility.
adopted_rename_cases() {
  local O X sibling retained other M mainline merge_order removed reviewed file=$'new\nname'
  local old=$'broken' refined=$'better' i
  for ((i=1; i<=60; i++)); do
    old+=$'\n'"original context $i"
    refined+=$'\n'"refined context $i"
  done
  g checkout -q --detach "$P"
  O=$(commit_file 'old path before adopted sibling history' "$old" old)
  X=$(commit_file 'independent repair later adopted by merge' "${old/broken/good}" old)
  g checkout -q --detach "$O"
  g mv old 'middle name'; g commit -q -m 'sibling renames original path'
  # Each refinement/rename has a detectable edge, but the endpoints do not.
  for ((i=1; i<=3; i++)); do
    sed -i "$((2 + (i - 1) * 20)),$((1 + i * 20))s/original/refined/" 'middle name'
    g add -A; g commit -q -m "sibling refinement $i"
  done
  g mv 'middle name' "$file"; g commit -q -m 'sibling chains rename before reviewed merge'
  C=$(commit_file 'blocked sibling change before adopting repair' broken bug)
  sibling=$C
  if git merge-base --is-ancestor "$X" "$sibling"; then fail 'adopted sibling history must not descend from X'; fi
  for merge_order in 1 2; do
    g checkout -q --detach "$sibling"
    other=$X
    if [ "$merge_order" = 2 ]; then g checkout -q --detach "$X"; other=$sibling; fi
    if ! g merge -q --no-ff --no-commit "$other" >"$T/merge.out" 2>&1; then
      [ -n "$(git ls-files -u)" ] || fail 'unexpected adopted sibling merge failure'
    fi
    rm -f old 'middle name'
    if [ "$merge_order" = 2 ]; then
      # Reusing the source name as a directory does not retain the old file.
      mkdir old; printf 'independent directory contents\n' > old/context
    fi
    printf '%s\n' "$refined" > "$file"
    printf 'good\n' > bug
    g add -A; g commit -q -m 'passing merge adopts and refines repair at sibling destination'
    D=$(git rev-parse HEAD)
    [ -z "$(git diff --name-only --find-renames=50% --diff-filter=R "$X" "$D")" ] || fail 'endpoint diff must not recover sibling rename'
    approval 0 "adopted sibling merge $merge_order before any revert"
    for mainline in 1 2; do
      # The unreviewed side descends from X, not D. The former proof treated
      # its undo as a preservation dependency on X without invalidating D.
      g checkout -q --detach "$X"
      other=$(commit_file 'unreviewed sibling descended from independent repair' side side)
      g checkout -q --detach "$X"
      g commit -q --allow-empty -m 'retain independent repair on unreviewed branch'
      retained=$(git rev-parse HEAD)
      if [ "$mainline" = 2 ]; then g checkout -q --detach "$other"; other=$retained; fi
      g merge -q --no-ff -m 'unreviewed sibling merge sharing only X' "$other"
      M=$(git rev-parse HEAD)
      if git merge-base --is-ancestor "$D" "$M"; then fail 'unreviewed merge must not descend from D'; fi
      g checkout -q --detach "$D"
      g merge -q --no-ff -m 'merge unreviewed sibling beside adopted repair' "$M"
      g revert --no-edit -m "$mainline" "$M" >/dev/null
      git diff --exit-code "$D" HEAD || fail 'sibling undo must retain exactly the reviewed tree'
      approval 1 "adopted sibling merge $merge_order mainline $mainline intact repair after undo"
      removed=$(commit_file 'remove reviewed repair at adopted destination' "${refined/better/broken}" "$file")
      approval 1 "adopted sibling merge $merge_order mainline $mainline removed repair"
      g revert --no-edit "$removed" >/dev/null
      approval 1 "adopted sibling merge $merge_order mainline $mainline restored repair after undo"
      reviewed=$D; D=$(git rev-parse HEAD)
      approval 0 "adopted sibling merge $merge_order mainline $mainline fresh full review"
      D=$reviewed
    done
  done
  echo 'exercised: adopted sibling rename history through both approval consumers'
}
if [ "${1:-}" = --adopted-sibling-renames ]; then
  adopted_rename_cases
  [ "$bad" = 0 ] || fail 'adopted sibling rename history bypassed full review'
  exit 0
fi

transform() { # transform <kind> → one commit on HEAD that moves / copies / re-modes D's repaired file
  case $1 in
    rename100) g mv old new; g commit -q -m 'rename old to new (R100)' ;;
    rename-edit) g mv old new; printf 'edited\n' >> new; g add new; g commit -q -m 'rename old to new with an edit (R<100)' ;;
    copy) cp old new; g add new; g commit -q -m 'copy old to new' ;;
    delete-add) cp old new; g rm -q old; g add new; g commit -q -m 'delete old, add new with its contents' ;;
    mode) chmod +x old; g add old; g commit -q -m 'make old executable' ;;
  esac
  git rev-parse HEAD
}
for kind in rename100 rename-edit copy delete-add mode; do
  g checkout -q --detach "$D"
  TR=$(transform "$kind")
  approval 0 "$kind without any revert: D still supersedes C (no needless full review)"
  g revert --no-edit "$TR" >/dev/null; RT=$(git rev-parse HEAD)
  approval 1 "$kind reverted directly"
  g revert --no-edit "$RT" >/dev/null
  approval 1 "$kind reverted and restored (revert of the revert)"
  # the transformation on a side branch, merged, the merge undone (git revert -m 1), the undo undone
  for mainline in 1 2; do
    g checkout -q --detach "$D"; side=$(commit_file 'unrelated side work' side side-file)
    g checkout -q --detach "$D"; TR=$(transform "$kind")
    if [ "$mainline" = 1 ]; then g merge -q --no-ff -m 'merge side work' "$side"; else g checkout -q --detach "$side"; g merge -q --no-ff -m 'merge the transformation' "$TR"; fi
    M=$(git rev-parse HEAD)
    approval 0 "$kind merged (mainline $mainline), no revert"
    g revert --no-edit -m "$mainline" "$M" >/dev/null; U=$(git rev-parse HEAD)
    approval 1 "$kind merge undone (revert -m $mainline)"
    g revert --no-edit "$U" >/dev/null
    approval 1 "$kind merge undone and redone (mainline $mainline)"
  done
  # a revert of D itself after the transformation (where git can apply it)
  g checkout -q --detach "$D"; transform "$kind" >/dev/null
  if g revert --no-edit "$D" >/dev/null 2>&1; then approval 1 "$kind then D reverted"; else g revert --abort 2>/dev/null || true; fi
done
echo "ok: rename / copy / delete+add / mode change: held without reverts, full review after any revert, restoration or merge undo"

# The 0cd95ca42 #1/#2 reproduction: X repairs old; D renames old → new (inside the passing review); sibling Q retains
# the repaired contents at both paths; M merges Q and D resolving exactly to D; U reverts M; V reverts U (D restored);
# reverting Q afterwards, resolving old as deleted, removes new too.
g checkout -q --detach "$P"
C=$(commit_file 'blocked: breaks old' broken-a old)
X=$(commit_file 'X repairs old' $'good-a\nrepaired' old)
g mv old new; g commit -q -m 'D: rename old to new'; D=$(git rev-parse HEAD)
g checkout -q --detach "$C"
printf 'good-a\nrepaired\n' > old; printf 'good-a\nrepaired\n' > new; g add old new; g commit -q -m 'Q retains the repair at old and new'; Q=$(git rev-parse HEAD)
g merge -q --no-ff --no-commit "$D" 2>/dev/null || true
g read-tree --reset -u "$D"; g commit -q -m 'M: merge Q and D, resolved to D exactly'; M=$(git rev-parse HEAD)
git diff --quiet "$D" "$M" || fail 'fixture: M is not D'
g revert --no-edit -m 1 "$M" >/dev/null; U=$(git rev-parse HEAD)
g revert --no-edit "$U" >/dev/null; V=$(git rev-parse HEAD)
git diff --quiet "$D" "$V" || fail 'fixture: V did not restore D'
approval 1 "0cd95ca42 #1/#2: merge undo and redo after D"
if ! g revert --no-edit "$Q" >/dev/null 2>&1; then g rm -q --cached old 2>/dev/null || true; rm -f old; g revert --continue >/dev/null 2>&1 || g commit -q -m "Revert Q" -m "This reverts commit $Q."; fi
approval 1 "0cd95ca42 #1/#2: sibling Q reverted after the redo"
echo "ok: the 0cd95ca42 reproduction needs a full review"

# Reverts arriving from elsewhere count too: one made on a side branch BEFORE D and merged after it, one on main merged in.
g checkout -q --detach "$P"
C=$(commit_file 'blocked: breaks old' broken-a old)
D=$(commit_file 'passing repair of old' $'good-a\nrepaired' old)
g checkout -q --detach "$C"; W=$(commit_file 'side work' w side-w); g revert --no-edit "$W" >/dev/null; SR=$(git rev-parse HEAD)
g checkout -q --detach "$D"; g merge -q --no-ff -m 'merge a side branch carrying an old revert' "$SR"
approval 1 "a revert brought in by a merge after D"
g checkout -q --detach "$P"; MW=$(commit_file 'main work' m main-w); g revert --no-edit "$MW" >/dev/null; MR=$(git rev-parse HEAD)
g checkout -q --detach "$D"; g merge -q --no-ff -m 'merge main into dev' "$MR"
approval 1 "a revert on main merged into dev after D"
# … but a revert INSIDE C..D was reviewed by D, and a message that only mentions a revert is none
g checkout -q --detach "$C"; Y=$(commit_file 'Y' y y-file); g revert --no-edit "$Y" >/dev/null
D=$(commit_file 'passing repair after an inner revert' $'good-a\nrepaired' old)
approval 0 "a revert inside C..D (reviewed by D)"
g commit -q --allow-empty -m 'docs: explain reverts' -m "Note: the dispatcher text says This reverts commit abcdef1 when it reverts."
approval 0 "a message that only mentions a revert mid-line"
adopted_rename_cases
[ "$bad" = 0 ] || fail 'supersession after reverts'
echo "dev supersession-after-reverts matrix passed"
