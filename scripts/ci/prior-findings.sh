#!/usr/bin/env bash
# prior-findings <base> <head> — the review ledger's input (owner 11-12): for every sha a Review-Fix-Of: trailer in
# base..head names, print the blocking findings of the newest failed Review run of that sha ("review <S>" on dev,
# "recheck <S>" on main) — the findings the fixer was given. review-gate.ts --prior puts them, with the fixers'
# Review-Disputed: trailers, into the re-review prompt. Read-only (GH_TOKEN with actions: read); prints nothing and
# exits 0 when there is nothing to fetch or the API fails: the re-review then reads the fix commits instead.
set -uo pipefail
REPO=${REPO:-${GITHUB_REPOSITORY:?REPO=owner/name is required}}
API=${GITHUB_API_URL:-https://api.github.com}
api() { curl -fsSL -m 30 -H "Authorization: Bearer ${GH_TOKEN:-}" -H "Accept: application/vnd.github+json" "$API/repos/$REPO/$1"; }
note() { echo "prior-findings: $*" >&2; }   # diagnostics go to the job log; stdout is the ledger
# only trailers that name an ancestor of their commit: a previous round's findings narrow the re-review (the reviewer
# treats ancestors of S as reviewed then), so a trailer naming a non-ancestor (tralyx fd935e7c5 → dev 1de3ade46, 11-14)
# must not attach S's round — that commit is reviewed as an ordinary commit
fixes=$(for c in $(git rev-list "$1..$2" 2>/dev/null); do
  for t in $(git show -s --format=%B "$c" | sed -nE 's/^Review-Fix-Of: ([0-9a-f]{40})[[:space:]]*$/\1/p'); do
    if [ "$t" != "$c" ] && git merge-base --is-ancestor "$t" "$c" 2>/dev/null; then echo "$t"
    else echo "prior-findings: ${c:0:12} names ${t:0:12}, not its ancestor — ignored" >&2; fi
  done
done | awk '!seen[$0]++')
[ -n "$fixes" ] || exit 0
# 11-13: the review.yml step ran without GH_TOKEN — every call was a 404 on the private repo and nothing said why
[ -n "${GH_TOKEN:-}" ] || { note "no GH_TOKEN — previous findings of $(tr '\n' ' ' <<<"$fixes")unavailable"; exit 0; }
review_api() { api "$1"; }
. "$(dirname "${BASH_SOURCE[0]}")/review-runs.sh"   # only trusted runs' findings reach the reviewer's prompt; every page
runs=$(review_runs completed | jq -s '{workflow_runs: .}')
for s in $fixes; do
  rid=$(jq -r --arg a "review $s" --arg b "recheck $s" \
    '[.workflow_runs[]? | select((.display_title == $a or .display_title == $b) and .conclusion == "failure")][0].id // empty' <<<"$runs" 2>/dev/null)
  [ -n "$rid" ] || { note "no failed review run found for ${s:0:12}"; continue; }
  jid=$(api "actions/runs/$rid/jobs" | jq -r '.jobs[]? | select((.name | sub("^.* / "; "")) == "review") | .id' 2>/dev/null | sed -n '1p')
  [ -n "$jid" ] || { note "run $rid (${s:0:12}): no review job"; continue; }
  out=$(api "actions/jobs/$jid/logs" | sed -E 's/^[^ ]+ //' | grep -E '^(review-gate: (BLOCKED|NIT)|evidence:)')
  if [ -n "$out" ]; then printf '== the review that blocked %s (run %s):\n%s\n' "$s" "$rid" "$out"; note "previous findings of ${s:0:12} attached (run $rid)"
  else note "run $rid (${s:0:12}): log unavailable or no findings in it"; fi
done
exit 0
