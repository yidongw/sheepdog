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
. "$(dirname "${BASH_SOURCE[0]}")/review-main-culprits.sh"   # review_main_culprits: THE rule review-passed.sh approves by
review_link() { # <run id> <link head> <anchor> <candidate head> <depth> [<title verb: review|recheck>]
  local att v
  att=$(review_attestation "$1" "$2") || return 1
  [ "$(jq -r .kind <<<"$att")" = review ] || return 1
  v=$(review_verdict "$1") || return 1
  # a link when it passed, or is repaired, or — a DEV review only — it blocked solely on pre-existing main findings: the
  # same rule review-passed.sh approves such a head by, so a head the train landed that way stays a link of later chains
  # (review of dev 5061f8b91 #1/#2). Never for a re-check (all of its culprits are on main by definition).
  [ "$v" = pass ] || repaired "$2" "$4" \
    || { [ "${6:-}" = review ] && review_main_culprits review_api "$1" "$2" >/dev/null 2>&1; } || return 1
  review_covered "$(jq -r .base <<<"$att")" "$3" "$4" "$5"
}
review_covered() { # <base> <anchor (deployed or review-time main)> <candidate head> [depth]
  local b=$1 d=$2 h=$3 n=${4:-0} id
  git merge-base --is-ancestor "$b" "$d" 2>/dev/null && return 0
  [ "$n" -lt 40 ] || return 1
  [ -n "${review_completed_runs:-}" ] || review_completed_runs=$(review_runs completed)
  local verb
  while read -r id verb; do
    [ -n "$id" ] || continue
    review_link "$id" "$b" "$d" "$h" "$((n + 1))" "$verb" && return 0
  done < <(jq -r --arg a "review $b" --arg r "recheck $b" '
    select(.display_title == $a or .display_title == $r) | "\(.id) \(.display_title | split(" ")[0])"' <<<"$review_completed_runs")
  if review_clean_merge "$b"; then
    review_covered "$(git rev-parse "$b^1")" "$d" "$h" "$((n + 1))" \
      && review_covered "$(git rev-parse "$b^2")" "$d" "$h" "$((n + 1))" && return 0
  fi
  return 1
}
