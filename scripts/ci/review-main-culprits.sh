#!/usr/bin/env bash
# Pre-existing MAIN findings in a dev review (supervisor 11-14: the dev review of 0cd95ca42, run 43577623889, blocked on
# FINDING #1/#2 commit=341cca4e9 — a commit already on main that the dev range carried in through a main→dev merge; the
# dispatcher woke a dev fixer for it, counted its round and sent fixfailed, and dev could never land).
#
# A blocking finding of a DEV review ("review <sha>") whose culprit commit — the reviewer's own `commit=` attribution, a
# full 40-hex sha — is an ancestor of the default branch as the review recorded it (the attestation's "main") and of the
# reviewed head is main's problem: main's own re-check chain owns it. It does not block the dev head. When EVERY blocking
# finding is such a main finding, the trusted tests passed and the review job failed in its blocking step only (range,
# gates, attestation passed; the reviewer ran and printed a well-formed verdict), the dev head stands as a passing review.
# Never when a finding has no culprit, the culprit is "-", abbreviated, unknown here or not on that main.
#
# Every reader decides it HERE, from the trusted run only (its jobs answer, its review job's log, its attestation) —
# never from the candidate: review-passed.sh (→ merge-branch.sh, the train, deployers) and review-dispatch.sh's routing.
# Sourced; runs in a clone that has the commits (the caller's cwd). The caller passes the name of its reader:
#   <api> <path below repos/<owner>/<repo>/> → the answer on stdout (JSON, log text or artifact bytes), non-zero on failure.

# mc_gate_lines <head> < review job log → the review gate's lines (timestamps removed) after the FIRST
# "review-gate: reviewing <base8>..<head8>" line the gate printed for <head>; 1 when there is none. Output of earlier
# steps (commit gates print commit messages) never counts: it comes before that line.
mc_gate_lines() {
  sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' | awk -v h="${1:0:8}" '
    $0 ~ ("^review-gate: reviewing [0-9a-f]+[.][.]" h "$") { seen = 1; next }
    seen && /^(review-gate: |evidence:)/ { L[++n] = $0 }
    END { if (!seen) exit 1; for (i = 1; i <= n; i++) print L[i] }'
}

# mc_classify <gate lines> <attested main> <head> → "<n> main|dev <commit|->" per blocking finding; 1 when the verdict is
# not well formed: no blocking finding, a reviewer failure line, a number twice, or a BLOCKED #n without exactly one
# "FINDING #n … commit=" line (or the reverse).
mc_classify() {
  local lines=$1 am=$2 h=$3 nums fnums n c cls
  grep -qE '^review-gate: (reviewer (failed|timed out)|no parseable|crashed|--pin-)' <<<"$lines" && return 1
  nums=$(sed -nE 's/^review-gate: BLOCKED #([0-9]+) .*/\1/p' <<<"$lines")
  fnums=$(sed -nE 's/^review-gate: FINDING #([0-9]+) .*/\1/p' <<<"$lines")
  [ -n "$nums" ] || return 1
  [ -z "$(sort <<<"$nums" | uniq -d)" ] && [ -z "$(sort <<<"$fnums" | uniq -d)" ] || return 1
  [ "$(sort -n <<<"$nums")" = "$(sort -n <<<"$fnums")" ] || return 1
  for n in $nums; do
    c=$(sed -nE "s/^review-gate: FINDING #$n route=[a-z]+ commit=([^ ]+)( .*)?\$/\\1/p" <<<"$lines")
    [ -n "$c" ] || return 1
    cls=dev
    if [[ "$c" =~ ^[0-9a-f]{40}$ ]] && git cat-file -e "$c^{commit}" 2>/dev/null \
       && git merge-base --is-ancestor "$c" "$am" 2>/dev/null && git merge-base --is-ancestor "$c" "$h" 2>/dev/null; then
      cls=main
    fi
    echo "$n $cls $c"
  done
}

# mc_run_qualifies <jobs json> → 0 when the trusted tests job passed and the review job failed in its blocking step and in
# no other step (a failed range, gates, pin or attestation step never ran the reviewer on an accepted range).
mc_run_qualifies() {
  jq -e '
    ([.jobs[]? | select((.name | sub("^.* / "; "")) == "tests" and .conclusion == "success")] | length > 0)
    and ([.jobs[]? | select((.name | sub("^.* / "; "")) == "review")] as $r
      | ($r | length) == 1 and $r[0].conclusion == "failure"
      and ([$r[0].steps[]? | select(.name | startswith("Review (blocking")) | .conclusion] == ["failure"])
      and ([$r[0].steps[]? | select((.name | startswith("Review (blocking") | not)
             and (.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out"))] | length == 0))' \
    <<<"$1" >/dev/null 2>&1
}

# review_main_culprits <api> <run id> <head> [<its jobs answer>] → prints "<n> main|dev <commit>" per blocking finding of
# that trusted dev review;
#   0 — EVERY blocking finding is a main finding and the run qualifies (mc_run_qualifies): the review stands as passed
#   1 — not so (some finding is the range's own, or the run does not qualify); the classification is printed
#   2 — no usable evidence (log, attestation of kind "review" for <head> with a recorded main, well-formed verdict)
review_main_culprits() {
  local api=$1 run=$2 h=$3 jobs=${4:-} jid log arts art dir att am lines cls
  [[ "$h" =~ ^[0-9a-f]{40}$ ]] || return 2
  [ -n "$jobs" ] || jobs=$("$api" "actions/runs/$run/jobs") || return 2
  jid=$(jq -r '[.jobs[]? | select((.name | sub("^.* / "; "")) == "review")][0].id // empty' <<<"$jobs" 2>/dev/null) || return 2
  [[ "$jid" =~ ^[0-9]+$ ]] || return 2
  log=$("$api" "actions/jobs/$jid/logs") || return 2
  lines=$(mc_gate_lines "$h" <<<"$log") || return 2
  arts=$("$api" "actions/runs/$run/artifacts") || return 2
  art=$(jq -r '[.artifacts[]? | select(.name == "review-attestation" and .expired != true)][0].id // empty' <<<"$arts" 2>/dev/null) || return 2
  [ -n "$art" ] || return 2
  dir=$(mktemp -d) || return 2
  if "$api" "actions/artifacts/$art/zip" > "$dir/a.zip" 2>/dev/null; then
    att=$(unzip -p "$dir/a.zip" review-attestation.json 2>/dev/null) || att=""
  else att=""; fi
  rm -rf "$dir"
  am=$(jq -er --arg h "$h" 'select(.head == $h and (.kind // "review") == "review" and (.main | type == "string")
        and (.main | test("^[0-9a-f]{40}$"))) | .main' <<<"$att" 2>/dev/null) || return 2
  git rev-parse -q --verify "$am^{commit}" >/dev/null 2>&1 || return 2
  cls=$(mc_classify "$lines" "$am" "$h") || return 2
  printf '%s\n' "$cls"
  mc_run_qualifies "$jobs" || return 1
  grep -q ' dev ' <<<"$cls" && return 1
  return 0
}
