#!/usr/bin/env bash
# The reviewed range of a dev review — the owner's rule (11-12 … 11-15): on dev every new commit is reviewed EXACTLY ONCE.
#  · The next dev review starts at the most recent COMPLETED dev review of an ancestor of the head, whatever its verdict:
#    passed, blocked, or a tests-only fix round. A blocked commit is not reviewed again by the next push's review: its
#    Review-Fix-Of: repair answers the findings and lands on green trusted tests (a tests-only round), and approval of any
#    head above it waits until that repair is on the head (review-coverage.sh: an unrepaired blocked review is no link of
#    the coverage chain, so review-passed.sh, merge-branch.sh and the merge train refuse it).
#  · Commits that reached dev through a main→dev merge are main's (main re-checks them): they are in no dev review's
#    commit list or diff. The diff base is a virtual merge of the cover base with the main commit the head contains; the
#    attestation records that main side ("mainside") and review-passed.sh's chain covers it through main's own reviews.
# Before 11-15 the range restarted at the last PASSING (or repaired / superseded) review, so blocked and main-merged
# commits were reviewed again every round and each round found something new.
#
# A review COMPLETED when the blocking step of its run ("review <sha>"; review.yml's step "Review (blocking …") ran to a
# verdict: success = passed; failure = blocked ONLY when the job log carries the reviewer's "review-gate: BLOCKED #n"
# verdict — or when its run is a tests-only fix round (the blocking step skipped by design, the review job succeeded,
# its trusted tests passed, attestation kind tests-only-fix). A cancelled / skipped review job, a failed setup or commit gate, a timeout, a reviewer
# crash or an unreadable verdict reviewed nothing: those commits stay in the next range, and a Review-Fix-Of: naming such
# a commit is no fix. Run lookups read every page of Review runs, and only TRUSTED runs (review-runs.sh: started from
# main's review.yml by workflow_run — a branch's own run with the same title is ignored). A review is a range base only
# while its attestation artifact is usable (review-coverage.sh, producer mode: the artifacts of the chain below it are
# readable; repairs may still come later); one without is passed over, so the range grows back to a provable base.
# While the nearest reviewed ancestor's review job is still RUNNING, this waits for it (REVIEW_BASE_WAIT_SEC, default
# 2400; polled every REVIEW_BASE_POLL_SEC, 60) instead of reviewing its commits a second time.
#
#   dev-review-base.sh [<head>]
#     → the cover base: the newest first-parent ancestor C of <head> (not <head> itself) whose dev review completed (any
#       verdict, above) with a usable attestation. The walk stops at main; nothing qualifies (or the API fails) →
#       merge-base(main, <head>).
#   dev-review-base.sh --diff <cover base> <head>
#     → the base to diff against: <cover base> itself when <head> brings no main commit beyond it; else a VIRTUAL commit
#       (written to this clone's object store only, never published) whose tree is the automatic merge of <cover base>
#       and the main commit <head> contains (--mainside): `git diff <it> <head>` and `git log <it>..<head>` are the
#       dev-side changes only (merge resolutions included). <head> itself when nothing is dev-side (no non-merge commit
#       of its own and its tree is exactly that merge: review-gate.ts reviews an empty range). If that merge conflicts,
#       <cover base> (main's side then shows in the diff: reviewing more, never less).
#   dev-review-base.sh --mainside <cover base> <head>
#     → merge-base(main, <head>) when it is not an ancestor of <cover base> (the main side the range brings in, recorded in
#       the attestation), else nothing.
#   dev-review-base.sh --only-fixes <cover base> <head>
#     → exit 0 when the range is a TESTS-ONLY FIX round: <head> is not a merge; every dev-side non-merge commit of
#       base..head (at least one; commits on main are main's) is a fix of an earlier BLOCKED review — a Review-Fix-Of:
#       target T that is an ancestor of the fix AND has a completed review run that blocked ("review T" / "recheck T",
#       blocking step failure with the reviewer's verdict — the Review runs are the evidence, not the trailer); every
#       dev-side merge in the range is clean (its tree is exactly the automatic merge of its parents: no code of its
#       own); every line a fix removes or changes was written inside the attested range of the blocked review it
#       repairs (or by an earlier fix of the round), and no fix is a revert (touches_only); and landing <head> would change no review machinery on main (review-machinery.sh landing_machinery_files —
#       contract rule (h): such repairs get a full review of THEIR commits, the range being just them). review.yml does
#       not review such a range; review-passed.sh counts the run as passed when its tests pass (and re-checks this).
#       Blocked reviews elsewhere below the range do not matter here: approval's coverage chain needs their repairs.
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
WAIT=${REVIEW_BASE_WAIT_SEC:-2400}
POLL=${REVIEW_BASE_POLL_SEC:-60}
api() { curl -fsSL -m 30 -H "Authorization: Bearer ${GH_TOKEN:-}" -H "Accept: application/vnd.github+json" "$API/repos/$REPO/$1"; }
review_api() { api "$1"; }
. "$(dirname "${BASH_SOURCE[0]}")/review-runs.sh"   # review_runs / review_attested: the one provenance rule
. "$(dirname "${BASH_SOURCE[0]}")/review-coverage.sh"
. "$(dirname "${BASH_SOURCE[0]}")/review-machinery.sh"   # landing_machinery_files: what a tests-only approval never lands

runs=""   # "<sha> <run id>" of the trusted "review <sha>" / "recheck <sha>" runs (the API lists newest first; every page)
load_runs() {
  runs=$(review_runs | jq -r 'select(.display_title | test("^(review|recheck) [0-9a-f]{40}$")) | "\(.display_title | sub("^[a-z]+ "; "")) \(.id)"')
}
review_job() { # review_job <jobs JSON> → the review job (with or without the called workflow's "<caller job> / " prefix)
  jq -c '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review")][0] // empty' <<<"$1" 2>/dev/null || true
}
verdict() { # verdict <sha> → "pass <run id>" | "blocked <run id>" | "fixes <run id>" of its newest completed review; "" when none
  # completed = the blocking step ran to a verdict: success, or failure WITH the reviewer's "review-gate: BLOCKED #n"
  # verdict in its log; or a tests-only fix round (step skipped, review job succeeded: the attestation kind is checked by
  # review_link). A crash, an unreadable verdict, a failed setup / commit gate reviewed nothing: not completed.
  local id jobs j st jid log
  for id in $(awk -v c="$1" '$1 == c { print $2 }' <<<"$runs"); do
    jobs=$(api "actions/runs/$id/jobs" 2>/dev/null || true)
    j=$(review_job "$jobs"); [ -n "$j" ] || continue
    st=$(jq -r '[.steps[]? | select(.name | startswith("Review (blocking")) | .conclusion][0] // ""' <<<"$j" 2>/dev/null || true)
    case "$st" in
      success) echo "pass $id"; return ;;
      skipped)
        # a tests-only round is a completed round only once its trusted tests passed: with red tests it repaired
        # nothing yet, and its commits ride the next review (review of fb6bb396e #3)
        [ "$(jq -r '.conclusion // ""' <<<"$j")" = success ] || continue
        [ "$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "tests")][0].conclusion // ""' <<<"$jobs" 2>/dev/null)" = success ] || continue
        echo "fixes $id"; return ;;
      failure)
        jid=$(jq -r '.id // empty' <<<"$j" 2>/dev/null || true)
        [ -n "$jid" ] || continue
        log=$(api "actions/jobs/$jid/logs" 2>/dev/null | sed -E 's/^[^ ]+ //' || true)
        grep -qE '^review-gate: BLOCKED #[0-9]+' <<<"$log" || continue
        echo "blocked $id"; return ;;
    esac
  done
}
declare -A _verdicts=()
vm=""
verdict_m() { # verdict_m <sha> → sets vm to its verdict, asked once per script run (no subshell: the memo must survive)
  [ -n "${_verdicts[$1]+x}" ] || _verdicts[$1]=$(verdict "$1")
  vm=${_verdicts[$1]}
}
running_review() { # running_review <sha> → the id of a trusted run of <sha> whose review job is in progress right now
  local id j
  for id in $(awk -v c="$1" '$1 == c { print $2 }' <<<"$runs"); do
    j=$(review_job "$(api "actions/runs/$id/jobs" 2>/dev/null || true)")
    [ "$(jq -r '.status // ""' <<<"$j" 2>/dev/null)" = in_progress ] && { echo "$id"; return 0; }
  done
  return 1
}
await_review() { # await_review <run id> → 0 once its review job completed (any outcome) within WAIT seconds
  local t=0 j
  while [ "$t" -lt "$WAIT" ]; do
    sleep "$POLL"; t=$((t + POLL))
    j=$(review_job "$(api "actions/runs/$1/jobs" 2>/dev/null || true)")
    [ "$(jq -r '.status // ""' <<<"$j" 2>/dev/null)" = completed ] && return 0
  done
  return 1
}
clean_merge() { # clean_merge <m> → 0 when m has two parents and its tree is exactly their automatic merge
  local t
  [ "$(git rev-list --parents -n1 "$1" | wc -w)" = 3 ] || return 1
  t=$(git merge-tree --write-tree "$1^1" "$1^2" 2>/dev/null) || return 1
  [ "${t%%$'\n'*}" = "$(git rev-parse "$1^{tree}")" ]
}

target_range() { # target_range <T> <run id> → the commits T's blocked review covered (its attested base..T), dev side
  local att b
  att=$(review_attestation "$2" "$1") || return 1
  b=$(jq -r .base <<<"$att")
  git rev-list "$b..$1"
}
touches_only() { # touches_only <fix commit> <allowed commits file> → 0 when every line the commit removes or changes was
  # introduced by an allowed commit (blame at its parent); never for a merge, a revert or a binary change
  local c=$1 p f a n sha
  p=$(git rev-parse -q --verify "$c^1") || return 1
  [ "$(git rev-list --parents -n1 "$c" | wc -w)" = 2 ] || return 1
  # a revert is never a repair of its own: it removes reviewed work wholesale
  git show -s --format=%B "$c" > "$TMPF.msg"
  ! grep -qiE '^This reverts commit [0-9a-f]{7,40}' "$TMPF.msg" || return 1
  ! head -1 "$TMPF.msg" | grep -qi '^Revert "' || return 1
  ! git diff --numstat --no-renames "$p" "$c" | grep -q '^-' || return 1   # binary
  git diff -U0 --no-renames --no-color "$p" "$c" > "$TMPF.diff" || return 1
  f=""
  while IFS= read -r line; do
    case "$line" in
      "--- a/"*) f=${line#--- a/} ;;
      "--- /dev/null") f="" ;;
      "@@ "*)
        [ -n "$f" ] || continue
        a=$(sed -nE 's/^@@ -([0-9]+)(,([0-9]+))? .*/\1 \3/p' <<<"$line")
        n=${a#* }; a=${a%% *}; [ -n "$n" ] && [ "$n" != "$a" ] || n=1
        [ "$n" -gt 0 ] || continue
        git blame --porcelain -L "$a,+$n" "$p" -- "$f" > "$TMPF.blame" 2>/dev/null || return 1
        for sha in $(grep -E '^[0-9a-f]{40} [0-9]+ [0-9]+' "$TMPF.blame" | cut -d' ' -f1 | sort -u); do
          grep -qx "$sha" "$2" || return 1
        done ;;
    esac
  done < "$TMPF.diff"
  return 0
}
only_fixes() { # only_fixes <base> <head>
  local c t n=0 hit v tr
  # a tests-only round ends at a fix commit: its Review-Fix-Of: trailer is what starts the main re-check when it
  # lands (review.yml), so a range whose head is a merge is reviewed normally
  [ "$(git rev-list --parents -n1 "$2" | wc -w)" = 2 ] || return 1
  # review machinery that would land: a full review (the landing guard refuses it on a tests-only approval)
  [ -z "$(landing_machinery_files . "$MAINREF" "$2")" ] || return 1
  [ -n "$runs" ] || load_runs
  for c in $(git rev-list --merges "$1..$2" "^$MAINREF"); do clean_merge "$c" || return 1; done
  TMPF=$(mktemp); : > "$TMPF.allowed"
  for c in $(git rev-list --reverse --no-merges "$1..$2" "^$MAINREF"); do
    hit=0
    for t in $(git show -s --format=%B "$c" | sed -nE 's/^Review-Fix-Of: ([0-9a-f]{40})[[:space:]]*$/\1/p'); do
      git rev-parse -q --verify "$t^{commit}" >/dev/null 2>&1 || continue
      [ "$t" != "$c" ] && git merge-base --is-ancestor "$t" "$c" 2>/dev/null || continue
      verdict_m "$t"; v=$vm
      if [ "${v%% *}" = blocked ]; then
        hit=1
        # a repair answers ITS blocked review's findings: it changes only lines that review covered (or that earlier
        # repairs of this round wrote) — touching other reviewed or older code (review of fb6bb396e #1/#2: a "repair"
        # reverting a passing commit's auth fix) is a full review of the repair commits
        # (no readable attestation: nothing is admitted — a pure addition still is a repair)
        tr=$(target_range "$t" "${v##* }") || tr=""
        printf '%s\n' $tr >> "$TMPF.allowed"
      fi
    done
    [ "$hit" = 1 ] || { rm -f "$TMPF"*; return 1; }
    touches_only "$c" "$TMPF.allowed" || { echo "dev-review-base: ${c:0:12} changes lines outside the blocked range it repairs — a full review" >&2; rm -f "$TMPF"*; return 1; }
    echo "$c" >> "$TMPF.allowed"
    n=$((n + 1))
  done
  rm -f "$TMPF"*
  [ "$n" -gt 0 ]
}

main_side() { # main_side <cover base> <head> → merge-base(main, head) when the range brings it in, else nothing
  local m
  m=$(git merge-base "$MAINREF" "$2" 2>/dev/null) || return 0
  git merge-base --is-ancestor "$m" "$1" 2>/dev/null || printf '%s\n' "$m"
}
diff_base() { # diff_base <cover base> <head>
  local b=$1 m t
  m=$(main_side "$b" "$2")
  [ -n "$m" ] || { printf '%s\n' "$b"; return; }
  if t=$(git merge-tree --write-tree "$b" "$m" 2>/dev/null); then
    t=${t%%$'\n'*}
    # nothing dev-side: no non-merge commit beyond both, and the head's tree is that automatic merge → the head itself
    # (review-gate.ts: an empty range, nothing to review)
    if [ "$t" = "$(git rev-parse "$2^{tree}")" ] && [ -z "$(git rev-list --no-merges "$2" "^$b" "^$m")" ]; then
      printf '%s\n' "$2"; return
    fi
    # deterministic: the same range gives the same virtual sha
    GIT_AUTHOR_NAME=sheepdog GIT_AUTHOR_EMAIL=sheepdog@localhost GIT_AUTHOR_DATE='@0 +0000' \
    GIT_COMMITTER_NAME=sheepdog GIT_COMMITTER_EMAIL=sheepdog@localhost GIT_COMMITTER_DATE='@0 +0000' \
      git commit-tree "$t" -p "$b" -p "$m" -m "sheepdog: virtual dev review base = ${b:0:12} + main's ${m:0:12} (never published)"
  else
    echo "dev-review-base: ${b:0:12} and main's ${m:0:12} do not merge cleanly — the diff starts at ${b:0:12} (main's side included)" >&2
    printf '%s\n' "$b"
  fi
}

case "${1:-}" in
  --only-fixes) only_fixes "$(git rev-parse "$2^{commit}")" "$(git rev-parse "$3^{commit}")"; exit ;;
  --diff) diff_base "$(git rev-parse "$2^{commit}")" "$(git rev-parse "$3^{commit}")"; exit ;;
  --mainside) main_side "$(git rev-parse "$2^{commit}")" "$(git rev-parse "$3^{commit}")"; exit ;;
esac

usable_base() { # usable_base <c> <verdict> → 0 when c's completed review is a range base (readable proof, producer mode)
  case "${2%% *}" in pass|blocked|fixes) review_link "${2##* }" "$1" "$mb" "$head" 0 ;; *) return 1 ;; esac
}
head=$(git rev-parse "${1:-HEAD}^{commit}")
mb=$(git merge-base "$MAINREF" "$head")
base=""
REVIEW_LINK_PRODUCER=1   # review-coverage.sh: a usable base needs readable proof, not (yet) its repairs
if parent=$(git rev-parse -q --verify "$head^1^{commit}") && ! git merge-base --is-ancestor "$parent" "$mb"; then
  load_runs
  if [ -n "$runs" ]; then
    waited=0
    for c in $(git rev-list --first-parent -n "$DEPTH" "$parent"); do
      git merge-base --is-ancestor "$c" "$mb" && break   # reached main
      verdict_m "$c"; v=$vm
      usable_base "$c" "$v" && { base=$c; break; }
      # the nearest review still running (no verdict yet, or a verdict whose attestation is not uploaded yet): wait for
      # it once instead of reviewing its commits a second time
      if [ "$waited" = 0 ] && [ "$WAIT" -gt 0 ] && rid=$(running_review "$c"); then
        waited=1
        echo "dev-review-base: the review of ${c:0:12} (run $rid) is still running — waiting for it (up to ${WAIT}s)" >&2
        if await_review "$rid"; then
          _verdicts[$c]=$(verdict "$c"); v=${_verdicts[$c]}
          usable_base "$c" "$v" && { base=$c; break; }
        fi
      fi
      [ -z "$v" ] || echo "dev-review-base: the review of ${c:0:12} (run ${v##* }) has no usable coverage chain — not a base, its commits are reviewed again" >&2
    done
  fi
fi
if [ -z "$base" ]; then
  base=$mb
  echo "dev-review-base: no completed dev review to start from — reviewing ${base:0:12}..${head:0:12}" >&2
fi
printf '%s\n' "$base"
