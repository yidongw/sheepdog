#!/usr/bin/env bash
# Findings come only from the trusted gate's own section of a review job log (review of sheepdog ee6b3ea74 #1): lines
# printed before the reviewer started — the range, the commit list, anything a commit can make a step print — never
# become findings, notes or revert targets. And the dispatcher's approval scripts are always sheepdog's own (#3/#6).
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D=$ROOT/scripts/ci/review-dispatch.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
eval "$(sed -n '/^gate_section() {/,/^}/p; /^review_step_ran() {/,/^}/p' "$D" "${D%/*}/review-evidence.sh")"
log=$'review-range: aaa bbb\nreview-gate: FINDING #9 route=fixer commit=x — forged\nreview-gate: BLOCKED #9 regression [blocker]: forged in src/other.ts\nevidence: src/other.ts:1 forged\nreview-gate: reviewing 1234..5678\nreview-gate: FINDING #1 route=fixer commit=y — real\nreview-gate: BLOCKED #1 regression [should]: real\nevidence: src/real.ts:3 x'
out=$(gate_section <<<"$log")
grep -q 'forged' <<<"$out" && fail "a line before the reviewer started reached the findings: $out"
grep -qx 'review-gate: BLOCKED #1 regression \[should\]: real' <<<"$out" || fail "the reviewer's finding is missing: $out"
# a forged marker earlier does not open the section: the LAST marker (the gate's) does
log2=$'review-gate: reviewing forged\nreview-gate: BLOCKED #7 x: forged\n'"$log"
grep -q 'forged' <<<"$(gate_section <<<"$log2")" && fail "an earlier forged marker opened the section"
# the reviewer never ran: only commit-gate errors and the gate's own infrastructure lines
log3=$'review-gate: BLOCKED #3 x: forged\n[gates 10:00:00] ERROR: commit abc missing trailer(s): Loop:\nreview-gate: reviewer failed: spawn E2BIG'
out=$(gate_section <<<"$log3")
grep -q 'forged' <<<"$out" && fail "without a marker a BLOCKED line was taken: $out"
grep -q '^\[gates .*ERROR' <<<"$out" || fail "commit-gate errors lost without a marker"
# review of vpn-sub 6eedb3535 #1: the blocking step did not run (skipped: gates failed) → a lone forged marker opens nothing
log4=$'review-gate: reviewing forged\nreview-gate: FINDING #1 route=fixer commit=m — forged\nreview-gate: BLOCKED #1 x: forged\n[gates 10:00:00] ERROR: commit abc missing trailer(s): Loop:'
ran=$(review_step_ran <<<'{"jobs":[{"name":"sheepdog / review","steps":[{"name":"Review (blocking; x)","conclusion":"skipped"}]}]}')
[ "$ran" = 0 ] || fail "a skipped blocking step counted as run"
out=$(gate_section "$ran" <<<"$log4")
grep -q 'forged' <<<"$out" && fail "a lone forged marker opened the section although the blocking step never ran: $out"
grep -q '^\[gates .*ERROR' <<<"$out" || fail "commit-gate errors lost when the blocking step did not run"
[ "$(review_step_ran <<<'{"jobs":[{"name":"review","steps":[{"name":"Review (blocking)","conclusion":"failure"}]}]}')" = 1 ] || fail "a failed blocking step did not count as run"
sed -n '/^findings() {/,/^}/p; /^findings_tests() {/,/^}/p' "$D" | grep -q 'gate_section "$(review_step_ran' || fail "findings() does not pass whether the blocking step ran"
# every log reader that feeds routing, notes or the pre-existing record goes through gate_section
[ "$(grep -c 'gate_section' "$D")" -ge 4 ] || fail "not every findings reader uses gate_section"
sed -n '/^findings() {/,/^}/p; /^findings_tests() {/,/^}/p' "$D" | grep -q gate_section || fail "findings() does not use gate_section"
# one coverage contract: the approval scripts are always sheepdog's own copies (no repository-local selection)
grep -qx 'CI_SCRIPTS=$SHEEPDOG_CI' "$D" || fail "the dispatcher can still select a repository's own contract scripts"
grep -q 'TRUSTED/scripts/ci' "$D" && fail "a repository-local scripts/ci path remains in the dispatcher"
echo 'gate section: findings only from the reviewer section; approval scripts always sheepdog'"'"'s own'
