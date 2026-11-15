#!/usr/bin/env bash
# THE eligibility rule for a blocked review round (sourced by dev-review-base.sh and review-passed.sh, owner 11-12:
# "if it fails, fix it once"): a round that BLOCKED at <S> counts — as a dev range base, as a link of deployment coverage — only
# when an effective repair of it is an ancestor of the head being judged: a commit in <S>..<head> carrying the exact
# trailer "Review-Fix-Of: <S>" (full sha) that has S as an ancestor and is not reverted since. Otherwise S's code is not vouched for by any later,
# unrelated review. (review-dispatch.sh's repair_effective is the dispatcher's richer form of the same rule.)
reverted() { # <c> <head> [depth] → 0 reverted · 1 NOT reverted (c stands) · 2 UNKNOWN (a git error, or past 64 levels).
  # Three states, propagated through the recursion: an unknown answer is never turned into "stands" or "reverted twice"
  # (review of sheepdog ae795a369 / 43721cf57 #1: a git error deep in the recursion read as "the undo itself was
  # reverted", so an undone repair counted as effective). Every caller treats 2 as "not effective" (fail closed).
  local x xs undos rc k=${3:-0}
  [ "$k" -lt 64 ] || return 2
  # A merge revert names the merge, not the repair it removes. Do not try to
  # prove retained contributions or restorations (supervisor 11-14): ANY merge
  # revert after c requires a new repair — conservative by policy (docs/contract.md).
  undos=$(git log --format=%H -i -E --grep='^This reverts commit [0-9a-f]{7,40}, reversing' "$1..$2" 2>/dev/null) || return 2
  [ -z "$undos" ] || return 0
  xs=$(git log --format=%H -F --grep="This reverts commit $1" "$1..$2" 2>/dev/null) || return 2
  for x in $xs; do
    rc=0; reverted "$x" "$2" $((k + 1)) || rc=$?
    case "$rc" in
      1) return 0 ;;   # x stands → c is reverted
      2) return 2 ;;   # unknown below → unknown here
    esac               # 0: x itself is reverted → it does not count against c
  done
  return 1
}
effective_repairs() { # <S> <head> → commits carrying effective repairs of S
  local c msg
  local cs rc
  cs=$(git log --format=%H -F --grep="Review-Fix-Of: $1" "$1..$2" 2>/dev/null) || return 0   # unreadable: no repair
  for c in $cs; do
    # Read the full message before matching; an early-closing grep -q can give git SIGPIPE under pipefail.
    msg=$(git show -s --format=%B "$c") || continue
    grep -qx "Review-Fix-Of: $1" <<<"$msg" || continue
    # the repair must descend from S (tralyx fd935e7c5, 11-14: a main hotfix naming a dev sha reached dev through a
    # main→dev merge and sat in S..head without containing S — a trailer that names no ancestor repairs nothing)
    git merge-base --is-ancestor "$1" "$c" 2>/dev/null || continue
    # only a repair known to stand counts (1); reverted (0) and unknown (2) do not
    rc=0; reverted "$c" "$2" || rc=$?
    if [ "$rc" = 1 ]; then printf '%s\n' "$c"; fi
  done
}
repaired() { # repaired <S> <head> → 0 when S..head carries an effective repair of S
  [ -n "$(effective_repairs "$1" "$2")" ]
}
