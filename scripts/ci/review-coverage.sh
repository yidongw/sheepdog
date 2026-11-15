#!/usr/bin/env bash
# Shared usable-proof rule for range producers and approval consumers. Source review-runs.sh first;
# callers pass only run ids from its trusted listing. Missing proof widens the range at production time.
# review_api returns JSON, log text or artifact bytes using the caller's existing authenticated client.
. "$(dirname "${BASH_SOURCE[0]}")/review-evidence.sh"   # the one evidence reader
review_verdict() { # <run id> -> pass|blocked; setup failures, cancellation and skips are not verdicts (exit 1);
  # exit 2 when the evidence could not be READ (API / log failure): unknown, which a caller deciding that a commit is
  # NOT blocked must treat as blocked (review of vpn-sub c3d6df140 #1)
  local jobs st jid log
  jobs=$(review_api "actions/runs/$1/jobs") || return 2
  st=$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review") | .steps[]?
    | select(.name | startswith("Review (blocking")) | .conclusion][0] // ""' <<<"$jobs") || return 2
  case "$st" in
    success) echo pass ;;
    failure)
      jid=$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review")][0].id // empty' <<<"$jobs")
      [ -n "$jid" ] || return 1
      # Consume the whole log before matching: grep -q in a pipe can SIGPIPE curl under pipefail.
      log=$(review_api "actions/jobs/$jid/logs") || return 2
      review_blocked_verdict "$jobs" "$log" || return 1
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
#  · historical main-only approvals (the rolled-back main-culprit feature, 11-14/15) are no links: coverage is needed only
#    from the deployed sha (prod) or main forward, and every head landed that way is already below it — tralyx
#    1f341ae94 / adf919018 are in its deployed tag, sheepdog 11638c93f / 84ada34cc on its main (review of ee6b3ea74 #7).
review_fix_links=""
review_fix_round() { # <run id> -> 0 when it is a completed tests-only fix round: review job succeeded, blocking step
  # skipped, and its trusted tests passed (a red round repaired nothing yet: review of fb6bb396e #3)
  local jobs
  jobs=$(review_api "actions/runs/$1/jobs") || return 1
  jq -e '([.jobs[]? | select((.name | sub("^.* / "; "")) == "review")][0] | select(.conclusion == "success")
    | [.steps[]? | select(.name | startswith("Review (blocking")) | .conclusion][0] == "skipped")
    and ([.jobs[]? | select((.name | sub("^.* / "; "")) == "tests")][0].conclusion == "success")' <<<"$jobs" >/dev/null 2>&1
}
review_recheck_blocked() { # <sha> <candidate head> [any] -> 0 when <sha>'s verdict is BLOCKED (or unknown) and no effective
  # repair of it is on <candidate head>. The verdict is THE one rule (review-evidence.sh review_first_verdict): the FIRST
  # completed, attested verdict of its "recheck <sha>" runs (with "any": "review <sha>" too), in run id / run_attempt
  # order. Later runs and reruns never change it; only a Review-Fix-Of: repair clears a block (owner 11-16; reviews of
  # sheepdog 04d883525 #1/#2, 12fe19739 #1-#3). Unknown (unreadable evidence, an earlier run not finished) is blocked.
  local rc=0 mode=recheck
  [ -z "${3:-}" ] || mode=any
  review_first_verdict "$1" "$mode" || rc=$?
  case "$rc" in
    1) return 1 ;;
    0) [ "$rfv_kind" = blocked ] || return 1 ;;
  esac
  if repaired "$1" "$2"; then return 1; else return 0; fi
}
# review_fix_links is transactional: a link (or a covered alternative) that fails restores what it had appended
review_link() { # <run id> <link head> <anchor> <candidate head> <depth> [<its verdict: pass|blocked|fixes> [<its validated
  # attestation JSON>] (review_first_verdict)]
  local saved=$review_fix_links
  _review_link "$@" && return 0
  review_fix_links=$saved; return 1
}
_review_link() {
  local att v m k am
  att=${7:-}; [ -n "$att" ] || att=$(review_attestation "$1" "$2") || return 1
  k=$(jq -r .kind <<<"$att")
  case "$k" in
    review)
      v=${6:-}; [ -n "$v" ] || v=$(review_verdict "$1") || return 1
      [ "$v" != fixes ] || return 1
      [ "$v" = pass ] || [ "${REVIEW_LINK_PRODUCER:-0}" = 1 ] || repaired "$2" "$4" || return 1 ;;
    tests-only-fix)
      case "${6:-}" in fixes) ;; "") review_fix_round "$1" || return 1 ;; *) return 1 ;; esac
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
  local b=$1 d=$2 h=$3 n=${4:-0} rc=0 vk vid vatt
  git merge-base --is-ancestor "$b" "$d" 2>/dev/null && return 0
  [ "$n" -lt 40 ] || return 1
  # THE verdict of <b> (review_first_verdict, "review <b>" or "recheck <b>"): its first completed, attested verdict is
  # the only run that can link it — a later pass never stands over a block, a later block never revokes a pass. A
  # blocked verdict links only with an effective repair on the head (the dev range PRODUCER takes any verdict as a
  # base: its repair may come later); an unknown verdict links nothing (fail closed; retried on the next run).
  review_first_verdict "$b" any || rc=$?
  vk=$rfv_kind vid=$rfv_id vatt=$rfv_att   # (nested links overwrite rfv_*)
  case "$rc" in
    0)
      review_link "$vid" "$b" "$d" "$h" "$((n + 1))" "$vk" "$vatt" && return 0
      # a blocked, unrepaired verdict: no structural coverage either (review of 1b2f4484e #1/#2)
      if [ "$vk" = blocked ] && [ "${REVIEW_LINK_PRODUCER:-0}" != 1 ] && ! repaired "$b" "$h"; then return 1; fi ;;
    2) return 1 ;;
  esac
  # structural coverage of a clean merge through its parents — never for a merge whose own verdict is blocked and not
  # repaired (above), nor an unknown one
  if review_clean_merge "$b"; then
    review_covered "$(git rev-parse "$b^1")" "$d" "$h" "$((n + 1))" \
      && review_covered "$(git rev-parse "$b^2")" "$d" "$h" "$((n + 1))" && return 0
  fi
  return 1
}
