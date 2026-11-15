#!/usr/bin/env bash
# Shared usable-proof rule for range producers and approval consumers. Source review-runs.sh first;
# callers pass only run ids from its trusted listing. Missing proof widens the range at production time.
# review_api returns JSON, log text or artifact bytes using the caller's existing authenticated client.
review_verdict() { # <run id> -> pass|blocked; setup failures, cancellation and skips are not verdicts
  local jobs st jid log
  jobs=$(review_api "actions/runs/$1/jobs") || return 1
  st=$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review") | .steps[]?
    | select(.name | startswith("Review (blocking")) | .conclusion][0] // ""' <<<"$jobs") || return 1
  case "$st" in
    success) echo pass ;;
    failure)
      jid=$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review")][0].id // empty' <<<"$jobs")
      [ -n "$jid" ] || return 1
      # Consume the whole log before matching: grep -q in a pipe can SIGPIPE curl under pipefail.
      log=$(review_api "actions/jobs/$jid/logs") || return 1
      grep -qE '^([^ ]+ )?review-gate: BLOCKED #[0-9]+' <<<"$log" || return 1
      echo blocked ;;
    *) return 1 ;;
  esac
}
review_attestation() { # <run id> <expected head> -> validated JSON; missing/expired/malformed fails closed
  local artifacts art dir att
  artifacts=$(review_api "actions/runs/$1/artifacts") || return 1
  art=$(jq -r '[.artifacts[]? | select(.name == "review-attestation" and .expired != true)][0].id // empty' <<<"$artifacts") || return 1
  [ -n "$art" ] || return 1
  dir=$(mktemp -d) || return 1
  if review_api "actions/artifacts/$art/zip" > "$dir/a.zip" \
      && unzip -p "$dir/a.zip" review-attestation.json > "$dir/att.json"; then
    att=$(jq -ce --arg h "$2" 'select(.head == $h and (.base | type == "string")
      and (.base | test("^[0-9a-f]{40}$"))) | .kind = (.kind // "review")
      | select(.kind == "review" or .kind == "tests-only-fix")' "$dir/att.json") || att=""
  else att=""; fi
  rm -rf "$dir"
  [ -n "$att" ] || return 1
  art=$(jq -r .base <<<"$att")
  [ "$art" != "$2" ] && git merge-base --is-ancestor "$art" "$2" 2>/dev/null || return 1
  printf '%s\n' "$att"
}
. "$(dirname "${BASH_SOURCE[0]}")/review-repair.sh"
review_clean_merge() {
  local t
  [ "$(git rev-list --parents -n1 "$1" | wc -w)" = 3 ] || return 1
  t=$(git merge-tree --write-tree "$1^1" "$1^2" 2>/dev/null) || return 1
  [ "${t%%$'\n'*}" = "$(git rev-parse "$1^{tree}")" ]
}
# review_link: the attested range base..<link head> of a trusted run is a link of the coverage chain of <candidate head>.
#  · a review link: the review passed, or it blocked and an effective Review-Fix-Of: repair of it is on <candidate head>
#    (review-repair.sh) — for the dev range PRODUCER (dev-review-base.sh sets REVIEW_LINK_PRODUCER=1) any completed
#    review is a base (its repair may come later: approval waits for it, the range does not), so no dev commit is
#    reviewed twice.
#  · a tests-only fix round (kind tests-only-fix, blocking step skipped, review job succeeded): a base for the dev
#    producer; a link for the APPROVAL consumers that opt in (review-passed.sh, review-covered.sh: REVIEW_LINK_FIXES=1)
#    only when its range re-checks as repairs of blocked reviews against the main boundary it recorded
#    (dev-review-base.sh --only-fixes). Its head is then added to review_fix_links: those fixes were reviewed by no dev
#    review, so merge-branch.sh lands a chain with them only as a head that main re-checks (rule (g)). Main's own range
#    producer (hotfix-review-base.sh) sets neither: a tests-only round is never a main base — main re-checks the fix.
#  · the attestation's "mainside" (a dev range that brought main commits in and did not review them): that main commit
#    must be covered in its own right (main's reviews, or below the anchor).
review_fix_links=""
review_fix_round() { # <run id> -> 0 when it is a completed tests-only fix round: review job succeeded, blocking step
  # skipped, and its trusted tests passed (a red round repaired nothing yet: review of fb6bb396e #3)
  local jobs
  jobs=$(review_api "actions/runs/$1/jobs") || return 1
  jq -e '([.jobs[]? | select((.name | sub("^.* / "; "")) == "review")][0] | select(.conclusion == "success")
    | [.steps[]? | select(.name | startswith("Review (blocking")) | .conclusion][0] == "skipped")
    and ([.jobs[]? | select((.name | sub("^.* / "; "")) == "tests")][0].conclusion == "success")' <<<"$jobs" >/dev/null 2>&1
}
review_recheck_blocked() { # <sha> <candidate head> [titles: recheck|any] -> 0 when a completed review of <sha> ("recheck
  # <sha>"; with "any" also "review <sha>") BLOCKED and no effective repair of it is on <candidate head>: main's safety
  # net for a tests-only fix has spoken against it, or (any) <sha> is an explicitly blocked commit
  local id
  [ -n "${review_completed_runs:-}" ] || review_completed_runs=$(review_runs completed)
  for id in $(jq -r --arg r "recheck $1" --arg a "${3:+review $1}" 'select(.display_title == $r or .display_title == $a) | .id' <<<"$review_completed_runs"); do
    [ "$(review_verdict "$id" 2>/dev/null || true)" = blocked ] || continue
    repaired "$1" "$2" || return 0
  done
  return 1
}
# review_fix_links is transactional: a link (or a covered alternative) that fails restores what it had appended
review_link() { # <run id> <link head> <anchor> <candidate head> <depth>
  local saved=$review_fix_links
  _review_link "$@" && return 0
  review_fix_links=$saved; return 1
}
_review_link() {
  local att v m k am
  att=$(review_attestation "$1" "$2") || return 1
  k=$(jq -r .kind <<<"$att")
  case "$k" in
    review)
      v=$(review_verdict "$1") || return 1
      [ "$v" = pass ] || [ "${REVIEW_LINK_PRODUCER:-0}" = 1 ] || repaired "$2" "$4" || return 1 ;;
    tests-only-fix)
      review_fix_round "$1" || return 1
      if [ "${REVIEW_LINK_PRODUCER:-0}" != 1 ]; then
        [ "${REVIEW_LINK_FIXES:-0}" = 1 ] || return 1
        ! review_recheck_blocked "$2" "$4" || return 1
        am=$(jq -r '.main // ""' <<<"$att")
        [[ "$am" =~ ^[0-9a-f]{40}$ ]] && git rev-parse -q --verify "$am^{commit}" >/dev/null 2>&1 || return 1
        (REPO=${REVIEW_REPO:-${REPO:-}} DEV_REVIEW_MAIN_REF=$am \
          bash "$(dirname "${BASH_SOURCE[0]}")/dev-review-base.sh" --only-fixes "$(jq -r .base <<<"$att")" "$2" >/dev/null 2>&1) || return 1
      fi ;;
    *) return 1 ;;
  esac
  m=$(jq -r '.mainside // ""' <<<"$att")
  if [ -n "$m" ]; then
    [[ "$m" =~ ^[0-9a-f]{40}$ ]] && git merge-base --is-ancestor "$m" "$2" 2>/dev/null || return 1
    review_covered "$m" "$3" "$4" "$(($5 + 1))" || return 1
  fi
  review_covered "$(jq -r .base <<<"$att")" "$3" "$4" "$5" || return 1
  if [ "$k" = tests-only-fix ] && [ "${REVIEW_LINK_PRODUCER:-0}" != 1 ]; then review_fix_links+="$2 "; fi
  return 0
}
review_covered() { # <base> <anchor (deployed or review-time main)> <candidate head> [depth]
  local saved=$review_fix_links
  _review_covered "$@" && return 0
  review_fix_links=$saved; return 1
}
_review_covered() {
  local b=$1 d=$2 h=$3 n=${4:-0} id
  git merge-base --is-ancestor "$b" "$d" 2>/dev/null && return 0
  [ "$n" -lt 40 ] || return 1
  [ -n "${review_completed_runs:-}" ] || review_completed_runs=$(review_runs completed)
  for id in $(jq -r --arg a "review $b" --arg r "recheck $b" '
    select(.display_title == $a or .display_title == $r) | .id' <<<"$review_completed_runs"); do
    review_link "$id" "$b" "$d" "$h" "$((n + 1))" && return 0
  done
  # structural coverage of a clean merge through its parents — never for a merge whose own review BLOCKED and is not
  # repaired: the dev producer starts the next range at it, so nothing else reviews it again (review of 1b2f4484e #1/#2)
  if review_clean_merge "$b" && ! review_recheck_blocked "$b" "$h" any; then
    review_covered "$(git rev-parse "$b^1")" "$d" "$h" "$((n + 1))" \
      && review_covered "$(git rev-parse "$b^2")" "$d" "$h" "$((n + 1))" && return 0
  fi
  return 1
}
