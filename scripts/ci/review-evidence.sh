#!/usr/bin/env bash
# THE reader of a review job's evidence (sourced by review-dispatch.sh, review-coverage.sh — and through it
# dev-review-base.sh, hotfix-review-base.sh, review-passed.sh, review-covered.sh — and prior-findings.sh): no caller scans a
# whole job log. A "review-gate:" line counts only when the blocking review step "Review (blocking …" actually ran
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
