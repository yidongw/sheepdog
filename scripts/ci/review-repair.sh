#!/usr/bin/env bash
# THE eligibility rule for a blocked review round (sourced by dev-review-base.sh and review-passed.sh, owner 11-12:
# "if it fails, fix it once"): a round that BLOCKED at <S> counts — as a dev range base, as a link of deployment coverage — only
# when an effective repair of it is an ancestor of the head being judged: a commit in <S>..<head> carrying the exact
# trailer "Review-Fix-Of: <S>" (full sha) that has S as an ancestor and is not reverted since. Otherwise S's code is not vouched for by any later,
# unrelated review. (review-dispatch.sh's repair_effective is the dispatcher's richer form of the same rule.)
reverted() { # reverted <c> <head> [depth] → 0 when a standing "This reverts commit <c>" sits in c..head (fail closed past 64)
  local x k=${3:-0}
  [ "$k" -lt 64 ] || return 0
  for x in $(git log --format=%H -F --grep="This reverts commit $1" "$1..$2" 2>/dev/null || true); do
    reverted "$x" "$2" $((k + 1)) || return 0   # x stands → c is reverted
  done
  return 1
}
effective_repairs() { # <S> <head> → commits carrying effective repairs of S
  local c msg
  for c in $(git log --format=%H -F --grep="Review-Fix-Of: $1" "$1..$2" 2>/dev/null || true); do
    # Read the full message before matching; an early-closing grep -q can give git SIGPIPE under pipefail.
    msg=$(git show -s --format=%B "$c") || continue
    grep -qx "Review-Fix-Of: $1" <<<"$msg" || continue
    # the repair must descend from S (tralyx fd935e7c5, 11-14: a main hotfix naming a dev sha reached dev through a
    # main→dev merge and sat in S..head without containing S — a trailer that names no ancestor repairs nothing)
    git merge-base --is-ancestor "$1" "$c" 2>/dev/null || continue
    if ! reverted "$c" "$2"; then printf '%s\n' "$c"; fi
  done
}
repaired() { # repaired <S> <head> → 0 when S..head carries an effective repair of S
  [ -n "$(effective_repairs "$1" "$2")" ]
}
