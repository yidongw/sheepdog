#!/usr/bin/env bash
# The reviewed range of a dev review (owner 11-12: "review on dev once; if it fails, fix once; when CI passes, merge into main without a second review";
# "every commit is reviewed once"). Mirrors main's scripts/ci/hotfix-review-base.sh: each dev commit is reviewed once — the next dev
# review covers only what no completed review has covered yet, and a range of only fixes of earlier blocked reviews is
# not reviewed again (its trusted tests still run and decide). Before 11-13 every dev round reviewed
# merge-base(main)..dev again: blocked, fixed, and the next round found something new in the same 38 commits.
#
# A review COMPLETED when the blocking step of its run ("review <sha>"; review.yml's step "Review (blocking …") ran to a
# verdict: success = passed (or a skipped fix range); failure = blocked ONLY when the job log carries the reviewer's
# "review-gate: BLOCKED #n" verdict. A cancelled / skipped review job, a failed setup or commit gate, a timeout, a reviewer
# crash or an unreadable verdict reviewed nothing: those commits stay in the range, and a Review-Fix-Of: naming such a
# commit is no fix. Run lookups read every page of Review runs (not only the newest 100), and only TRUSTED runs
# (review-runs.sh: started from main's review.yml by workflow_run — a branch's own run with the same title is ignored).
# A review is a range base only while its attestation artifact is usable (review-passed.sh's chain needs it); one without
# is passed over, so the range grows back to a base the approval consumer can prove.
#
#   dev-review-base.sh [<head>]
#     → the cover base: the newest first-parent ancestor C of <head> (not <head> itself) whose dev review completed and
#       either PASSED, or BLOCKED and C..<head> carries an effective repair of C (a commit with "Review-Fix-Of: C" that
#       is not reverted). A blocked C without its repair is passed over, and from then on the base may be no newer
#       than the base C's own review used (its "review-range:" line): C's whole range is reviewed again together with
#       the new commits — a blocked commit never lands on an unrelated commit's review, whatever was repaired above it.
#       The walk stops at main; nothing qualifies (or the API fails) → merge-base(origin/main, <head>), or the older
#       limit a passed-over blocked review set.
#   dev-review-base.sh --diff <cover base> <head>
#     → the base to diff against: the cover base moved past clean main→dev merges right above it (their main side was
#       reviewed on main), mirroring main's move past dev train merges. A real, published commit.
#   dev-review-base.sh --only-fixes <cover base> <head>
#     → exit 0 when every dev-side non-merge commit of base..head (at least one; commits on main are main's) is a fix
#       of an earlier BLOCKED review: a Review-Fix-Of: target T that is an ancestor of the fix
#       AND has a completed review run that blocked ("review T" / "recheck T", blocking step failure — the Review
#       runs are the evidence, not the candidate's trailer); and every dev-side merge in the range is clean (its tree is
#       exactly the automatic merge of its two parents: no code of its own), and no dev commit in OR BELOW the range
#       (down to main; merges included) is a blocked, unrepaired review (that one is reviewed again) — a blocked review
#       whose whole range a later completed review re-reviewed, and that later review passed or is repaired, is
#       superseded: it needs no repair of its own (superseded()). review.yml does not review such a range
#       again (REVIEW_SKIP); review-passed.sh counts the run as passed when its tests pass.
#       Never when landing <head> would change review machinery on main (review-machinery.sh landing_machinery_files —
#       the same definition the dispatcher's and merge-branch.sh's landing guard use: a tests-only approval never lands
#       machinery, so such a range gets the full review instead of a tests-only round nothing could land; review of dev
#       c6dfe26bb #3).
#
# "main" is DEV_REVIEW_MAIN_REF (default origin/main). review.yml pins it to the sha origin/main had at review time and
# records it in the attestation ("main"); review-passed.sh re-checks a tests-only round against that same boundary, so
# the answer does not change when main later advances onto the approved fix.
#
# Run in the candidate checkout (full history, origin/main present). GH_TOKEN (actions: read), REPO.
set -euo pipefail
MAINREF=${DEV_REVIEW_MAIN_REF:-origin/main}
REPO=${REPO:-${GITHUB_REPOSITORY:?REPO=owner/name is required}}
API=${GITHUB_API_URL:-https://api.github.com}
DEPTH=${REVIEW_BASE_DEPTH:-80}
api() { curl -fsSL -m 30 -H "Authorization: Bearer ${GH_TOKEN:-}" -H "Accept: application/vnd.github+json" "$API/repos/$REPO/$1"; }
review_api() { api "$1"; }
. "$(dirname "${BASH_SOURCE[0]}")/review-runs.sh"   # review_runs / review_attested: the one provenance rule
. "$(dirname "${BASH_SOURCE[0]}")/review-coverage.sh"

runs=""   # "<sha> <run id>" of the trusted "review <sha>" / "recheck <sha>" runs (the API lists newest first; every page)
load_runs() {
  runs=$(review_runs | jq -r 'select(.display_title | test("^(review|recheck) [0-9a-f]{40}$")) | "\(.display_title | sub("^[a-z]+ "; "")) \(.id)"')
}
verdict() { # verdict <sha> → "pass <run id>" | "blocked <base its review used, or -> <run id>" of its newest completed review; "" when none
  # completed = the blocking step ran to a verdict: success, or failure WITH the reviewer's "review-gate: BLOCKED #n"
  # verdict in its log. A crash, an unreadable verdict, a failed setup / commit gate reviewed nothing: not completed.
  local id jobs st jid log rb
  for id in $(awk -v c="$1" '$1 == c { print $2 }' <<<"$runs"); do
    jobs=$(api "actions/runs/$id/jobs" 2>/dev/null || true)
    st=$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review") | .steps[]? | select(.name | startswith("Review (blocking")) | .conclusion][0] // ""' <<<"$jobs" 2>/dev/null || true)
    case "$st" in
      success) echo "pass $id"; return ;;
      failure)
        jid=$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review")][0].id // empty' <<<"$jobs" 2>/dev/null || true)
        [ -n "$jid" ] || continue
        log=$(api "actions/jobs/$jid/logs" 2>/dev/null | sed -E 's/^[^ ]+ //' || true)
        grep -qE '^review-gate: BLOCKED #[0-9]+' <<<"$log" || continue
        rb=$(sed -nE 's/^review-range: ([0-9a-f]{40}) [0-9a-f]{40}$/\1/p' <<<"$log"); rb=${rb%%$'\n'*}   # no head: an early-closed pipe dies of SIGPIPE under pipefail
        echo "blocked ${rb:--} $id"; return ;;
    esac
  done
}
run_base() { # run_base <run id> → the base of the range that run reviewed (its "review-range:" line); "" when unknown
  local jobs jid log rb
  jobs=$(api "actions/runs/$1/jobs" 2>/dev/null || true)
  jid=$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review")][0].id // empty' <<<"$jobs" 2>/dev/null || true)
  [ -n "$jid" ] || return 0
  log=$(api "actions/jobs/$jid/logs" 2>/dev/null | sed -E 's/^[^ ]+ //' || true)
  rb=$(sed -nE 's/^review-range: ([0-9a-f]{40}) [0-9a-f]{40}$/\1/p' <<<"$log"); printf '%s\n' "${rb%%$'\n'*}"
}
declare -A _verdicts=()
vm=""
verdict_m() { # verdict_m <sha> → sets vm to its verdict, asked once per script run (no subshell: the memo must survive)
  [ -n "${_verdicts[$1]+x}" ] || _verdicts[$1]=$(verdict "$1")
  vm=${_verdicts[$1]}
}
preserves_patch() ( # preserves_patch <before> <after> <at commit> [<literal paths>...]
  # Candidate attributes (notably merge=union) can hide a real conflict and
  # return the post-revert tree unchanged. Prove preservation in an isolated
  # bare repository: info/attributes has priority over every tree's attributes,
  # and forces Git's built-in conflict-detecting text driver on every path.
  # Borrow objects read-only; temporary merge results stay in the proof repo.
  local proof merged before=$1 after=$2 at=$3
  proof=$(mktemp -d) || return 1
  trap 'rm -rf "$proof"' EXIT
  git init -q --bare --template= "$proof" || return 1
  mkdir -p "$proof/info" || return 1
  git rev-parse --path-format=absolute --git-path objects > "$proof/objects/info/alternates" || return 1
  printf '%s\n' '* merge=text' > "$proof/info/attributes" || return 1
  if [ "$#" -gt 3 ]; then
    # Project the approved result onto the constituent's paths. Other paths
    # stay at the baseline, so their old deltas impose no obligation at head.
    # Candidate diff settings must not hide gitlinks or emit display-only
    # output which apply --allow-empty could mistake for an empty patch.
    shift 3
    git --git-dir="$proof" read-tree "$before" || return 1
    git --literal-pathspecs diff --binary --full-index --no-renames --no-ext-diff --no-textconv \
      --no-color --ignore-submodules=none --submodule=short "$before" "$after" -- "$@" |
      git --git-dir="$proof" apply --cached --allow-empty || return 1
    after=$(git --git-dir="$proof" write-tree) || return 1
    after=$(git --git-dir="$proof" -c user.name=review-proof -c user.email=review-proof@invalid \
      commit-tree "$after" -p "$before" --no-gpg-sign -m 'scoped reviewed contribution') || return 1
  fi
  merged=$(GIT_ATTR_NOSYSTEM=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git --git-dir="$proof" -c core.attributesFile=/dev/null -c merge.renormalize=false \
    merge-tree --write-tree --merge-base="$before" "$after" "$at" 2>/dev/null) || return 1
  [ "$merged" = "$(git rev-parse "$at^{tree}")" ]
)
restores_patch() { # <reverted commit> <undo> [<contribution before> <after> [<paths>...]]
  # A containing merge undo may also remove unreviewed changes. Carry the
  # original contribution through recursion, in the current revert direction,
  # so restoring it need not restore those unrelated changes too. Both ends
  # must prove the complete delta; a matching final snapshot alone is unsafe.
  if [ "$#" -ge 4 ] && ! git --literal-pathspecs diff --quiet --ignore-submodules=none "$3" "$4" -- "${@:5}" &&
    preserves_patch "$4" "$3" "$1^1" "${@:5}" && preserves_patch "$3" "$4" "$1" "${@:5}" &&
    preserves_patch "$3" "$4" "$2^1" "${@:5}" && preserves_patch "$4" "$3" "$2" "${@:5}"; then
    return 0
  fi
  # The full revert delta also proves restoration (including partial removals
  # of a contribution, for which the contextual inverse is not complete).
  git rev-parse --verify "$1^1" >/dev/null 2>&1 || return 1
  if git diff --quiet --ignore-submodules=none "$1^1" "$1"; then return 1; fi
  # An exact restoration of the whole pre-revert tree is complete even
  # when intervening conflicts erased the reverted patch from the parent.
  # Retain the contextual proof above for selective restoration.
  if git diff --quiet --ignore-submodules=none "$1^1" "$2"; then return 0; fi
  preserves_patch "$1^1" "$1" "$2^1" && preserves_patch "$1" "$1^1" "$2"
}
reverts_of() { # <commit> <since> <head> [restore [<contribution before> <after> [<paths>...]]]
  # Git names the merge, not its constituent commits, in a merge revert. Only
  # commits introduced relative to the recorded mainline can be undone by it.
  # For restoration, prove both patch directions: the constituent's complete
  # delta survives in the undo's parent, and its inverse survives after the
  # undo. Unrelated hunks may differ at either endpoint. Final contents alone
  # prove nothing when constituents cancel inside the merge.
  # In invalidation mode, mark a merge undo that retained the patch as
  # "<sha> preserved". Its consumer must verify preservation through head;
  # the snapshot alone cannot vouch for later reverts of a sibling cherry-pick.
  local c=$1 since=$2 h=$3 restore=${4:-0} r m p body
  local -a context=("${@:5}")
  while read -r r; do
    if [ "$restore" = 1 ]; then restores_patch "$c" "$r" "${context[@]}" || continue; fi
    printf '%s\n' "$r"
  done < <(git log --format=%H -F --grep="This reverts commit $c" "$since..$h" 2>/dev/null)
  while read -r r; do
    body=$(git show -s --format=%B "$r")
    m=$(sed -nE 's/^This reverts commit ([0-9a-f]{40}), reversing$/\1/p' <<<"$body")
    p=$(sed -nE 's/^changes made to ([0-9a-f]{40})\.$/\1/p' <<<"$body")
    [[ "$m" =~ ^[0-9a-f]{40}$ && "$p" =~ ^[0-9a-f]{40}$ ]] || continue
    # The named mainline must be an actual parent, not an arbitrary ancestor.
    git rev-list --parents -n1 "$m" 2>/dev/null | cut -d' ' -f2- | tr ' ' '\n' | grep -qxF "$p" || continue
    git merge-base --is-ancestor "$c" "$m" 2>/dev/null || continue
    if git merge-base --is-ancestor "$c" "$p" 2>/dev/null; then
      # Shared ancestry is retained, not restored by this merge undo. Keep its
      # reviewed contribution as a dependency too: a later revert of an
      # equivalent on that mainline can remove it without naming c.
      if [ "$restore" != 1 ]; then printf '%s preserved\n' "$r"; fi
      continue
    fi
    # Reachability only identifies a possible constituent. An equivalent patch
    # can already live on the retained mainline (e.g. a cherry-pick). If applying
    # c's delta to the post-revert tree is a clean no-op, its reviewed changes
    # survived at this snapshot, even with unrelated edits in the same file.
    # Keep that dependency visible to the caller rather than discarding r.
    if [ "$restore" != 1 ]; then
      if preserves_patch "$c^1" "$c" "$r"; then
        printf '%s preserved\n' "$r"
        continue
      fi
    fi
    if [ "$restore" = 1 ]; then
      restores_patch "$c" "$r" "${context[@]}" || continue
    fi
    printf '%s\n' "$r"
  done < <(git log --format=%H -F --grep=', reversing' "$since..$h" 2>/dev/null)
}
revert_state() { # revert_state <r> <head> [depth] → 0: r stands in r..head · 1: r is undone (a standing revert of it) ·
  # 2: unknown (a revert chain deeper than 64). Tri-state, so the depth limit never flips a verdict by parity: a caller
  # that needs "undone" to proceed treats 2 as "stands" (review of sheepdog ea594cc26 #1/#2: review-repair.sh reverted()
  # answers "reverted" at its limit — fail-closed for a repair, fail-OPEN when it is asked whether a revert was undone).
  # Both direct and merge undos use reverts_of's recorded-mainline and complete
  # restoration checks. An ancestry-only fallback would accept partial undos.
  local r=$1 h=$2 k=${3:-0} x st unknown=0
  local -a context=("${@:4}") inverse=()
  if [ "${#context[@]}" -ge 2 ]; then inverse=("${context[1]}" "${context[0]}" "${context[@]:2}"); fi
  [ "$k" -lt 64 ] || return 2
  for x in $(reverts_of "$r" "$r" "$h" 1 "${context[@]}"); do
    st=0; revert_state "$x" "$h" $((k + 1)) "${inverse[@]}" || st=$?
    case "$st" in 0) return 1 ;; 2) unknown=1 ;; esac
  done
  [ "$unknown" = 0 ] || return 2
  return 0
}
contribution_paths() { # <constituent> <reviewed head> -> NUL-delimited path lineage
  local x=$1 d=$2 path status old new
  local -A paths=()
  while IFS= read -r -d '' path; do paths["$path"]=1; done < <(
    git diff --no-renames --ignore-submodules=none --name-only -z "$x^1" "$x")
  # Walk reviewed rename edges, rather than comparing only the endpoints:
  # successive refinements can make the final name too dissimilar to x.
  # Include both ends so the projection carries the deletion AND destination.
  while IFS= read -r -d '' status && IFS= read -r -d '' old && IFS= read -r -d '' new; do
    [ -n "${paths[$old]+x}" ] || continue
    paths["$new"]=1
  done < <(git log --format= --reverse --topo-order --diff-merges=separate \
    --name-status -z --find-renames=50% -l0 --diff-filter=R --no-color \
    --no-ext-diff --no-textconv --ignore-submodules=none "$x..$d")
  [ "${#paths[@]}" = 0 ] || printf '%s\0' "${!paths[@]}"
}
contribution_stands() { # <constituent> <approved head> <candidate> <depth>
  local x=$1 d=$2 h=$3 k=$4 l v rb att
  local -a paths=()
  mapfile -d '' -t paths < <(contribution_paths "$x" "$d")
  [ "${#paths[@]}" -gt 0 ] || return 0
  # If D still contains x's original patch, require just that patch. Otherwise
  # D refined or cancelled x: use D's net result along x's path lineage.
  if preserves_patch "$x^1" "$x" "$d"; then
    preserves_patch "$x^1" "$x" "$h" && return 0
  else
    preserves_patch "$x^1" "$d" "$h" "${paths[@]}" && return 0
  fi
  [ "$k" -lt 40 ] || return 1
  # Later incremental reviews may replace this contribution. They must cover
  # every change since D through a usable full-review chain, pass, and their own
  # reviewed contributions must still stand. A skipped, gapped, side-branch,
  # blocked or reverted review cannot bless an arbitrary new endpoint.
  for l in $(git rev-list "$d..$h" "^$MAINREF" 2>/dev/null); do
    git merge-base --is-ancestor "$d" "$l" 2>/dev/null || continue
    verdict_m "$l"; v=$vm
    [ "${v%% *}" = pass ] || continue
    att=$(review_attestation "${v##* }" "$l") || continue
    [ "$(jq -r .kind <<<"$att")" = review ] || continue
    rb=$(jq -r .base <<<"$att")
    review_covered "$rb" "$d" "$h" 0 || continue
    review_stands "$rb" "$l" "$h" "$((k + 1))" || continue
    mapfile -d '' -t paths < <(contribution_paths "$x" "$l")
    preserves_patch "$x^1" "$l" "$h" "${paths[@]}" && return 0
  done
  return 1
}
review_stands() { # <reviewed range base> <reviewed head> <candidate> <depth>
  local b=$1 d=$2 h=$3 k=$4 x r preservation st
  local -a context=() paths=()
  for x in $(git rev-list "$b..$d" 2>/dev/null); do
    while read -r r preservation; do
      if [ "$preservation" = preserved ]; then
        # Retained equivalents outside the reviewed ancestry must survive at
        # head, accounting for refinements and subsequent reviewed changes.
        contribution_stands "$x" "$d" "$h" "$k" || return 1
        continue
      fi
      # Use the reviewed range's net contribution: one containing undo can
      # remove several successive refinements together. Its unreviewed side
      # changes impose no restoration obligation, even within the same file.
      mapfile -d '' -t paths < <(contribution_paths "$x" "$d")
      context=("$d" "$b" "${paths[@]}")
      st=0; revert_state "$r" "$h" 0 "${context[@]}" || st=$?
      [ "$st" = 1 ] || return 1
      # An undo is evidence at its own snapshot. A later merge resolution can
      # discard it, or adjacent edits can make a subsequent undo unprovable.
      # Require the reviewed contribution at the candidate as well, using the
      # same scoped proof / independently reviewed replacements as retention.
      contribution_stands "$x" "$d" "$h" "$k" || return 1
    done < <(reverts_of "$x" "$d" "$h")
  done
  return 0
}
superseded() { # superseded <C> <the base C's blocked review used, or -> <head> → 0 when a LATER completed dev review re-reviewed
  # all of C's range and stands: a review of a descendant D of C (C is an ancestor of D; D in C..head, not on main) whose own range started at or
  # below C's (its review-range base is an ancestor of C's base, so every commit C's review saw was in D's) and that passed,
  # or blocked and is repaired in D..head. C's own block then needs no repair of its own: its code had its one review again
  # in D's round, and D's findings — C's still-open ones among them — are what the repairs answer (owner 11-13: dev gets one
  # review; tralyx 11-13/14: dev heads blocked and superseded at once by a main→dev merge — 4b6671346, bc1f40bd3,
  # f54379cfd — were never repaired by trailer, so no range above them could ever be a tests-only round again).
  local c=$1 rc=$2 h=$3 d v rb
  [[ "$rc" =~ ^[0-9a-f]{40}$ ]] || return 1
  for d in $(git rev-list "$c..$h" "^$MAINREF" 2>/dev/null); do
    # one containment rule (as repaired()): D's head contains C — a review on a side branch merged in later never saw C
    git merge-base --is-ancestor "$c" "$d" 2>/dev/null || continue
    verdict_m "$d"; v=$vm
    case "${v%% *}" in
      blocked) rb=${v#blocked }; rb=${rb%% *}; repaired "$d" "$h" || continue ;;
      pass) rb=$(run_base "${v##* }") ;;
      *) continue ;;
    esac
    [[ "$rb" =~ ^[0-9a-f]{40}$ ]] || continue
    # D's range began at or below C's, and C is inside it
    git merge-base --is-ancestor "$rb" "$rc" 2>/dev/null && ! git merge-base --is-ancestor "$c" "$rb" 2>/dev/null || continue
    # and what D's review vouched for still stands: no standing revert AFTER D (in D..head) of D or of any commit D's
    # review saw above C (review of foxhole-backend b4d18dbbc #1: a passing fix reverted later restored C's blocked code,
    # and D's pass still superseded C's block). A revert inside C..D was itself reviewed by D: it disqualifies nothing
    # (review of sheepdog 87dce4aec #1). Only a revert that is itself undone (revert_state 1) is ignored.
    review_stands "$c" "$d" "$h" 0 || continue
    return 0
  done
  return 1
}
. "$(dirname "${BASH_SOURCE[0]}")/review-repair.sh"   # reverted / repaired: the one repair rule
. "$(dirname "${BASH_SOURCE[0]}")/review-machinery.sh"   # landing_machinery_files: what a tests-only approval never lands
clean_merge() { # clean_merge <m> → 0 when m has two parents and its tree is exactly their automatic merge
  local t
  [ "$(git rev-list --parents -n1 "$1" | wc -w)" = 3 ] || return 1
  t=$(git merge-tree --write-tree "$1^1" "$1^2" 2>/dev/null) || return 1
  [ "${t%%$'\n'*}" = "$(git rev-parse "$1^{tree}")" ]
}

only_fixes() { # only_fixes <base> <head>
  local c t n=0 hit v
  # a tests-only round ends at a fix commit: its Review-Fix-Of: trailer is what starts the main re-check when it
  # lands (review.yml), so a range whose head is a merge is reviewed normally
  [ "$(git rev-list --parents -n1 "$2" | wc -w)" = 2 ] || return 1
  # review machinery that would land: a full review (the landing guard refuses it on a tests-only approval)
  [ -z "$(landing_machinery_files . "$MAINREF" "$2")" ] || return 1
  [ -n "$runs" ] || load_runs
  # no blocked, unrepaired review in or below the range (down to main), merges included: that one is reviewed again —
  # unless a later completed review that stands re-reviewed its whole range (superseded)
  for c in $(git rev-list "$2" "^$MAINREF"); do
    verdict_m "$c"; v=$vm
    if [ "${v%% *}" = blocked ] && ! repaired "$c" "$2"; then
      local rcb=${v#blocked }; rcb=${rcb%% *}
      superseded "$c" "$rcb" "$2" || return 1
    fi
  done
  for c in $(git rev-list --merges "$1..$2" "^$MAINREF"); do clean_merge "$c" || return 1; done
  for c in $(git rev-list --no-merges "$1..$2" "^$MAINREF"); do
    hit=0
    for t in $(git show -s --format=%B "$c" | sed -nE 's/^Review-Fix-Of: ([0-9a-f]{40})[[:space:]]*$/\1/p'); do
      git rev-parse -q --verify "$t^{commit}" >/dev/null 2>&1 || continue
      [ "$t" != "$c" ] && git merge-base --is-ancestor "$t" "$c" 2>/dev/null || continue
      verdict_m "$t"; v=$vm
      if [ "${v%% *}" = blocked ]; then hit=1; break; fi
    done
    [ "$hit" = 1 ] || return 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

diff_base() { # diff_base <cover base> <head>
  local b=$1 h=$2 n
  while n=$(git rev-list --first-parent --reverse "$b..$h" | sed -n '1p') && [ -n "$n" ] && [ "$n" != "$h" ]; do
    clean_merge "$n" && git merge-base --is-ancestor "$n^2" "$MAINREF" 2>/dev/null || break
    review_covered "$n" "$b" "$h" || break
    b=$n
  done
  printf '%s\n' "$b"
}

case "${1:-}" in
  --only-fixes) only_fixes "$(git rev-parse "$2^{commit}")" "$(git rev-parse "$3^{commit}")"; exit ;;
  --diff) diff_base "$(git rev-parse "$2^{commit}")" "$(git rev-parse "$3^{commit}")"; exit ;;
esac

head=$(git rev-parse "${1:-HEAD}^{commit}")
mb=$(git merge-base "$MAINREF" "$head")
base=""
limit=""   # passing over a blocked, unrepaired R: the base may be no newer than the base R's own review used
if parent=$(git rev-parse -q --verify "$head^1^{commit}") && ! git merge-base --is-ancestor "$parent" "$mb"; then
  load_runs
  if [ -n "$runs" ]; then
    for c in $(git rev-list --first-parent -n "$DEPTH" "$parent"); do
      git merge-base --is-ancestor "$c" "$mb" && break   # reached main
      v=$(verdict "$c")
      case "${v%% *}" in
        pass|blocked)
          if [ "${v%% *}" = pass ] || repaired "$c" "$head"; then
            if ! review_link "${v##* }" "$c" "$mb" "$head" 0; then
              echo "dev-review-base: the review of ${c:0:12} (run ${v##* }) has no usable coverage chain — not a base, its commits are reviewed again" >&2
              continue
            fi
            if [ -z "$limit" ] || git merge-base --is-ancestor "$c" "$limit"; then base=$c; break; fi
            continue
          fi
          s=${v#blocked }; s=${s%% *}
          if [ "$s" = - ] || ! git merge-base --is-ancestor "$s" "$c" 2>/dev/null; then s=$mb; fi
          if [ -z "$limit" ]; then limit=$s; else limit=$(git merge-base "$limit" "$s"); fi
          echo "dev-review-base: ${c:0:12} was blocked and is not repaired in ${c:0:12}..${head:0:12} — its range (from ${s:0:12}) is reviewed again" >&2 ;;
      esac
    done
  fi
fi
if [ -z "$base" ]; then
  base=$mb
  if [ -n "$limit" ]; then base=$(git merge-base "$mb" "$limit"); fi
  echo "dev-review-base: no completed dev review to start from — reviewing ${base:0:12}..${head:0:12}" >&2
fi
printf '%s\n' "$base"
