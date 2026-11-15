#!/usr/bin/env bash
# THE reader of a review job's evidence — and of a commit's verdict (review_first_verdict, below: its FIRST completed,
# attested verdict in run id / run_attempt order; every consumer asks it). Sourced by review-dispatch.sh,
# review-coverage.sh — and through it dev-review-base.sh, hotfix-review-base.sh, review-passed.sh, review-covered.sh —
# and prior-findings.sh. No caller scans a whole job log. A "review-gate:" line counts only when the blocking review step "Review (blocking …" actually ran
# (review_step_ran) AND it comes after the LAST "review-gate: reviewing" marker (review-gate.ts prints it when the reviewer
# starts). Anything printed before the reviewer started — the range, a commit list, a gate's echo of a commit message —
# or in a job whose blocking step never ran is not a finding and not a verdict (reviews of sheepdog ee6b3ea74 #1, vpn-sub
# 6eedb3535 #1, twitter-monitor 4c6e5cf42 #1: forged FINDING / BLOCKED lines selected revert targets, held rounds and
# made never-reviewed commits a range base).
review_step_ran() { # stdin: a run's jobs answer → 1 when its review job's blocking step concluded success / failure, else 0
  jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review")][0] | [.steps[]? | select(.name | startswith("Review (blocking")) | .conclusion][0] // ""
    | if . == "success" or . == "failure" then 1 else 0 end' 2>/dev/null || echo 0
}
gate_section() { # stdin: a review job log WITHOUT timestamps; [<ran>] (default 1) → the gate's own lines: after the last
  # marker when the step ran; otherwise (no marker, or the step did not run) no "review-gate:" verdict line at all — only
  # commit-gate errors, plus the gate's own infrastructure lines when the step ran
  awk -v ran="${1:-1}" '{ l[NR] = $0 } /^review-gate: reviewing / { m = NR }
    END { if (ran != 0 && m) { for (i = m + 1; i <= NR; i++) print l[i] }
          else { for (i = 1; i <= NR; i++) if (l[i] ~ (ran != 0 ? "^(\\[gates .*ERROR|review-gate: (reviewer|no parseable|crashed))" : "^\\[gates .*ERROR")) print l[i] } }'
}
review_log_lines() { # stdin: a raw job log (GitHub's timestamp prefix on every line); [<ran>] → gate_section of it
  sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+ //' | gate_section "${1:-1}"
}
review_blocked_verdict() { # <jobs answer> <raw review job log> → 0 when the reviewer's own section carries "review-gate:
  # BLOCKED #n" and the blocking step ran: the only evidence a review BLOCKED (a crash, a gate failure or forged text is not)
  local ran
  ran=$(review_step_ran <<<"$1")
  [ "$ran" = 1 ] || return 1
  grep -qE '^review-gate: BLOCKED #[0-9]+' <<<"$(review_log_lines 1 <<<"$2")"
}

# ── THE verdict of a commit (owner 11-16; replaces every "newest verdict" / completion-time order) ──
# Every dev commit is reviewed EXACTLY ONCE, and a blocked commit is cleared only by an effective Review-Fix-Of: repair —
# never by a later review or rerun. So a commit's verdict is its FIRST completed verdict: the trusted runs titled
# "<title> <sha>" are ordered by (run id ascending, then run_attempt ascending) — both monotonic GitHub fields; never
# timestamps, never the listing order — and the first attempt whose review job ran to a verdict decides:
#   pass     the blocking step "Review (blocking …" succeeded AND the run carries a valid review attestation for <sha>
#            (kind review). An unattested pass proves no range: it is no verdict (skipped).
#   blocked  the blocking step failed with the reviewer's own "review-gate: BLOCKED #n" (review_blocked_verdict). The
#            reviewer's BLOCKED line in the step that ran is a block's evidence; it does not depend on the artifact
#            (deleting a blocked run's artifact must not turn a later pass into the verdict).
#   fixes    a tests-only fix round (dev): blocking step skipped, review job succeeded, that attempt's trusted tests
#            passed, attestation kind tests-only-fix.
# No verdict (skipped): no review job in a completed attempt, a cancelled / skipped / timed-out step, a reviewer crash or
# a gate failure (failure without the reviewer's BLOCKED line), an unattested pass or round.
# UNKNOWN (exit 2, fail closed: callers treat it as blocked; the dispatcher retries next run): the listing, an earlier
# candidate's jobs answer, log or attestation could not be read, or an earlier candidate has not completed yet (it may
# still produce the first verdict).
# Later runs and reruns of the same commit never change the verdict.
#
#   review_first_verdict <sha> <review|recheck|any>   (titles: "review <sha>" | "recheck <sha>" | either)
#     → 0 and sets rfv_kind (pass|blocked|fixes), rfv_id, rfv_attempt, rfv_jobs (that attempt's jobs answer),
#       rfv_latest_jobs (the run's latest attempt), rfv_run (the run's listing object), rfv_att (its validated
#       attestation JSON for a pass / tests-only round); 1 when no candidate has a verdict yet; 2 unknown (rfv_id /
#       rfv_attempt: where).
#     Call it WITHOUT a subshell to read the rfv_* results; review_first_verdict_line prints "<kind> <run id> <attempt>"
#     ("unknown <run id> <attempt>" / nothing) and returns the same status.
# The caller defines review_api <path below repos/<owner>/<repo>/> (JSON, log text or artifact bytes; non-zero on
# failure) and either review_verdict_list (→ the trusted runs, one JSON object per line: id, display_title, status
# [, run_attempt — else read from the latest attempt's jobs]) or sources review-runs.sh first (review_runs_strict, every
# status). Attestation ancestry is checked in the clone at $REVIEW_GIT_DIR (default: the current directory).
declare -gA _rfv_memo=() _rfv_jobs_memo=() _rfv_run_memo=() _rfv_latest_memo=() _rfv_att_memo=()
rfv_kind="" rfv_id="" rfv_attempt="" rfv_jobs="" rfv_run="" rfv_latest_jobs="" rfv_att=""
review_verdict_runs="" review_verdict_listed=0
review_verdict_load() { # the trusted listing the verdicts are read from, once per process (call it before forking subshells)
  [ "${review_verdict_listed:-0}" != 1 ] || return 0
  if declare -F review_verdict_list >/dev/null; then review_verdict_runs=$(review_verdict_list) || return 2
  else review_verdict_runs=$(review_runs_strict) || return 2; fi
  review_verdict_listed=1
}
review_attested_kind() { # <run id> <sha> <attempt> <latest attempt> → prints "<kind> <attestation JSON>" of THAT attempt
  # (kind review | tests-only-fix); 1 none / invalid; 2 unreadable. review.yml uploads "review-attestation-<attempt>"
  # with run_id / run_attempt inside (review of 9ce09a6e2 #3: a run-wide artifact let a historical attempt borrow a
  # later attempt's broader range). A legacy "review-attestation" (pins before f0b03471f's successor; no run fields)
  # belongs to an attempt only when the run never had another one.
  local a art d k b at=${3:-1} n=${4:-1}
  a=$(review_api "actions/runs/$1/artifacts") || return 2
  art=$(jq -r --arg name "review-attestation-$at" --arg at "$at" --arg n "$n" '[.artifacts[]? | select(.expired != true)
    | select(.name == $name or (.name == "review-attestation" and $at == "1" and $n == "1"))][0].id // empty' <<<"$a" 2>/dev/null) || return 2
  [ -n "$art" ] || return 1
  d=$(mktemp -d) || return 2
  if ! review_api "actions/artifacts/$art/zip" > "$d/a.zip" 2>/dev/null; then rm -rf "$d"; return 2; fi
  if ! unzip -p "$d/a.zip" review-attestation.json > "$d/att.json" 2>/dev/null; then rm -rf "$d"; return 2; fi
  a=$(jq -c --arg h "$2" --arg id "$1" --arg at "$at" --arg n "$n" 'select(.head == $h and (.base | type == "string") and (.base | test("^[0-9a-f]{40}$")))
    | select(((.run_id | tostring) == $id and (.run_attempt | tostring) == $at)
             or (.run_id == null and .run_attempt == null and $at == "1" and $n == "1"))
    | .kind = (.kind // "review")' "$d/att.json" 2>/dev/null) || a=""
  rm -rf "$d"
  [ -n "$a" ] || return 1
  k=$(jq -r .kind <<<"$a"); b=$(jq -r .base <<<"$a")
  case "$k" in review|tests-only-fix) ;; *) return 1 ;; esac
  [ "$b" != "$2" ] && git ${REVIEW_GIT_DIR:+-C "$REVIEW_GIT_DIR"} merge-base --is-ancestor "$b" "$2" 2>/dev/null || return 1
  printf '%s %s\n' "$k" "$a"
}
review_attempt_verdict() { # <run id> <attempt> <sha> <jobs answer> <run completed 0|1> <latest attempt> → prints
  # "pass <attestation>" | "blocked [<attestation>]" | "fixes <attestation>"; 1 no verdict; 2 unknown
  local j st jid log k rc
  j=$(jq -c '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review")][0] // empty' <<<"$4" 2>/dev/null) || return 2
  if [ -z "$j" ]; then [ "$5" = 1 ] && return 1; return 2; fi   # not created yet: it may still review
  [ "$(jq -r '.status // "completed"' <<<"$j")" = completed ] || return 2   # not finished: it may still decide
  st=$(jq -r '[.steps[]? | select(.name | startswith("Review (blocking")) | .conclusion][0] // ""' <<<"$j") || return 2
  case "$st" in
    success)
      rc=0; k=$(review_attested_kind "$1" "$3" "$2" "$6") || rc=$?
      [ "$rc" != 2 ] || return 2
      [ "$rc" = 0 ] && [ "${k%% *}" = review ] || return 1   # an unattested pass is no verdict
      echo "pass ${k#* }" ;;
    failure)
      jid=$(jq -r '.id // empty' <<<"$j")
      [ -n "$jid" ] || return 2
      log=$(review_api "actions/jobs/$jid/logs") || return 2
      review_blocked_verdict "$4" "$log" || return 1   # a crash / gate failure reviewed nothing
      # a block needs no artifact to stand; its range (repair scope, a repaired link) comes from this attempt only — read
      # unless the caller routes only (REVIEW_VERDICT_RANGES=0: the dispatcher, never an approval consumer)
      if [ "${REVIEW_VERDICT_RANGES:-1}" = 1 ]; then
        k=$(review_attested_kind "$1" "$3" "$2" "$6") && [ "${k%% *}" = review ] && { echo "blocked ${k#* }"; return 0; }
      fi
      echo blocked ;;
    skipped)
      [ "$(jq -r '.conclusion // ""' <<<"$j")" = success ] || return 1
      # its trusted tests still running: the round may still become one (unknown, never skipped past)
      [ "$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "tests")][0] | .status // "completed"' <<<"$4" 2>/dev/null)" = completed ] || return 2
      [ "$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "tests")][0].conclusion // ""' <<<"$4" 2>/dev/null)" = success ] || return 1
      rc=0; k=$(review_attested_kind "$1" "$3" "$2" "$6") || rc=$?
      [ "$rc" != 2 ] || return 2
      [ "$rc" = 0 ] && [ "${k%% *}" = tests-only-fix ] || return 1
      echo "fixes ${k#* }" ;;
    *) return 1 ;;
  esac
}
review_first_verdict() { # see above
  local sha=$1 mode=${2:-any} key r id="" n k="" jobs="" latest v rc done_
  declare -gA _rfv_memo _rfv_jobs_memo _rfv_run_memo _rfv_latest_memo _rfv_att_memo   # (no reset: a no-op once declared)
  key="$sha $mode"
  rfv_kind="" rfv_id="" rfv_attempt="" rfv_jobs="" rfv_run="" rfv_latest_jobs="" rfv_att=""
  if [ -n "${_rfv_memo[$key]+x}" ]; then
    read -r rc rfv_kind rfv_id rfv_attempt <<<"${_rfv_memo[$key]}"
    [ "$rfv_kind" != - ] || rfv_kind=""; [ "$rfv_id" != - ] || rfv_id=""; [ "$rfv_attempt" != - ] || rfv_attempt=""
    rfv_jobs=${_rfv_jobs_memo[$key]:-}; rfv_run=${_rfv_run_memo[$key]:-}; rfv_latest_jobs=${_rfv_latest_memo[$key]:-}; rfv_att=${_rfv_att_memo[$key]:-}
    return "$rc"
  fi
  review_verdict_load || return 2
  rc=1
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    id=$(jq -r .id <<<"$r"); k=1
    done_=0; [ "$(jq -r '.status // "completed"' <<<"$r")" = completed ] && done_=1
    # the latest attempt's jobs first; the attempt count from the listing (REST: run_attempt) or, when the listing has
    # none (gh run list), from those jobs (each carries its run_attempt)
    latest=$(review_api "actions/runs/$id/jobs") || { rc=2; break; }
    n=$(jq -r --argjson l "$latest" '.run_attempt // ([$l.jobs[]?.run_attempt // empty] | max) // 1' <<<"$r" 2>/dev/null) || { rc=2; break; }
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { rc=2; break; }
    for k in $(seq 1 "$n"); do
      if [ "$k" = "$n" ]; then jobs=$latest
      else jobs=$(review_api "actions/runs/$id/attempts/$k/jobs") || { rc=2; break 2; }; fi
      # an earlier attempt is over (a rerun exists); only the latest attempt of an unfinished run may still review
      local fin=1; [ "$k" = "$n" ] && fin=$done_
      # a run is never evidence about itself: the review job reading this (REVIEW_SELF_RUN="<run id> <attempt>", set by
      # review.yml's range step) skips its own unfinished attempt — earlier attempts and runs still decide (review of
      # 9ce09a6e2 #1/#2: the classifier vetoed its own repair-only range as "unknown")
      if [ "$id $k" = "${REVIEW_SELF_RUN:-}" ] && [ "$fin" = 0 ] \
         && [ "$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review")][0].status // ""' <<<"$jobs")" != completed ]; then continue; fi
      v=$(review_attempt_verdict "$id" "$k" "$sha" "$jobs" "$fin" "$n") && { rfv_kind=${v%% *}; [ "$v" = "$rfv_kind" ] || rfv_att=${v#* }; rc=0; break 2; }
      [ $? = 1 ] || { rc=2; break 2; }
    done
  done < <(jq -c --arg r "review $sha" --arg c "recheck $sha" --arg m "$mode" '
      select((($m == "review" or $m == "any") and .display_title == $r) or (($m == "recheck" or $m == "any") and .display_title == $c))
      | . + {status: (.status // "completed")}' <<<"$review_verdict_runs" 2>/dev/null | jq -sc 'sort_by(.id)[]')
  if [ "$rc" != 1 ]; then rfv_id=$id; rfv_attempt=$k; rfv_run=$r; fi
  [ "$rc" != 0 ] || { rfv_jobs=$jobs; rfv_latest_jobs=$latest; }
  _rfv_memo[$key]="$rc ${rfv_kind:--} ${rfv_id:--} ${rfv_attempt:--}"; _rfv_jobs_memo[$key]=$rfv_jobs; _rfv_run_memo[$key]=$rfv_run; _rfv_latest_memo[$key]=$rfv_latest_jobs; _rfv_att_memo[$key]=$rfv_att
  return "$rc"
}
review_first_verdict_line() { # <sha> <mode> → "<kind> <run id> <attempt>" | "unknown <run id> <attempt>" | nothing; the status of review_first_verdict
  local rc=0
  review_first_verdict "$@" || rc=$?
  case "$rc" in 0) echo "$rfv_kind $rfv_id $rfv_attempt" ;; 2) echo "unknown ${rfv_id:--} ${rfv_attempt:--}" ;; esac
  return "$rc"
}
