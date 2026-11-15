#!/usr/bin/env bash
# THE verdict of a commit (owner 11-16; review-evidence.sh review_first_verdict): its FIRST completed, attested review
# verdict — the trusted runs of that commit ordered by (run id ascending, run_attempt ascending), never by timestamps or
# the listing order; the first attempt whose review job ran to a verdict (pass / blocked / a tests-only round) decides.
# Later runs and reruns never change it; runs without a verdict (crash, cancel, infra) are skipped; an unattested pass
# is no verdict; an earlier run that cannot be read (or has not finished) makes the verdict UNKNOWN → treated as
# blocked (fail closed). Every consumer reads it: review-passed.sh / review-coverage.sh (approval, coverage links,
# main's tests-only withdrawal), dev-review-base.sh (range base, repair targets), hotfix-review-base.sh, prior-findings.sh.
#
# The reviewer fixtures of the escalated design question, each with ONE defined answer now:
#   (1) run 43739966889 #1/#2 (review of 04d883525): tests-only run 21 of F, a passing re-check 20 of F WITHOUT an
#       attestation, an older re-check 10 of F whose attempt 2 blocked → F's verdict: blocked (run 10, attempt 2); F refused
#   (2) run 43741546870 #1/#2 (review of c914d9ca0): tests-only round 14 of F, re-check 15 of F blocked on its rerun
#       (attempt 2), re-check 20 of F passing later with failing tests → F's main verdict blocked (15/2): the tests-only
#       approval is withdrawn; F refused
#   (3) runs 43741546870 #3 / 43741742877 #3: A's run 24 failed and its log is unreadable, run 25 passed A later →
#       A's verdict unknown → blocked: F refused (and once run 24's log reads as a crash, run 25's pass is A's verdict)
#   (4) run 43741742877 #1/#2: run 14 passed A (its job finished late), run 15 blocked A (its job finished first) →
#       A's verdict: pass (run 14), whatever the completion times; the other way round (14 blocked, 15 passed): blocked
#   (5) attempts of one run: attempt 1 decides over attempt 2, both ways
#   (6) an earlier run not finished / unreadable jobs / unreadable attestation → unknown
#   (7) prior-findings.sh attaches the FIRST blocked round of the repaired commit, not a later rerun's
#   (8) a merge-only commit whose tree is main's own is covered from main whatever its review said (tralyx e964c6539)
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
ROOT=$PWD
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$ROOT/test/ci/lib/review-first-fixture.sh"

# control: the plain chain approves F's tests-only round
reset; chain; run1 21 "review $F" skipped "$N"
expect "$F" any "fixes 21 1" "control"
rp "$F" o/r "$P" || fail "control: the tests-only round F was not approved"

# (1) run 43739966889: re-check 10 of F (attempt 1 crashed, attempt 2 blocked), re-check 20 of F passed WITHOUT an attestation
reset; chain; run1 21 "review $F" skipped "$N"
listing 20 "recheck $F" 1 completed success; attempt 20 1 1 success                  # no attestation
listing 10 "recheck $F" 2 completed failure; attempt 10 1 2 crash; attempt 10 2 2 failure; att 10 "$F" "$N"
expect "$F" any "blocked 10 2" "(1)"
expect "$F" recheck "blocked 10 2" "(1)"
if rp "$F" o/r "$P"; then fail "(1) F approved over its first verdict (blocked re-check 10, attempt 2)"; fi
# … without run 10: the unattested pass 20 is no verdict; the tests-only round 21 is
reset; chain; run1 21 "review $F" skipped "$N"; listing 20 "recheck $F" 1 completed success; attempt 20 1 1 success
expect "$F" any "fixes 21 1" "(1) an unattested pass is no verdict"
expect "$F" recheck "none" "(1) an unattested pass is no main verdict"
rp "$F" o/r "$P" || fail "(1) control: the unattested pass blocked the tests-only round"
echo "ok (1) - an unattested pass is no verdict; the blocked attempt of the older re-check is F's verdict"

# (2) run 43741546870 #1/#2: tests-only 14 of F; re-check 15 of F blocked on attempt 2; re-check 20 passed later (red tests)
reset; chain; run1 14 "review $F" skipped "$N"
listing 15 "recheck $F" 2 completed failure; attempt 15 1 2 crash; attempt 15 2 2 failure; att 15 "$F" "$N"
listing 20 "recheck $F" 1 completed failure; attempt 20 1 1 success failure; att 20 "$F" "$N"
expect "$F" any "fixes 14 1" "(2) the dev verdict"
expect "$F" recheck "blocked 15 2" "(2) the main verdict"
if rp "$F" o/r "$P"; then fail "(2) the later passing re-check 20 revived F's tests-only approval over the blocked re-check 15"; fi
echo "ok (2) - the first main verdict (blocked rerun of re-check 15) withdraws the tests-only approval; re-check 20 changes nothing"

# (3) runs 43741546870 #3 / 43741742877 #3: A's run 9 failed, its log unreadable; run 25 passed A
reset; chain; run1 21 "review $F" skipped "$N"
listing 9 "review $A" 1 completed failure; attempt 9 1 1 failure; att 9 "$A" "$P"; rm -f "$T/api/91.log"
run1 25 "review $A" success "$P"
expect "$A" any "unknown 9 1" "(3) an unreadable earlier log"
if rp "$F" o/r "$P"; then fail "(3) an unknown first verdict of A (run 9's log unreadable) was not blocked"; fi
attempt 9 1 1 crash   # the log reads now: a crash is no verdict → run 11 (pass) is A's verdict
expect "$A" any "pass 11 1" "(3) a crash is skipped"
rp "$F" o/r "$P" || fail "(3) once readable as a crash, run 9 still blocked A"
echo "ok (3) - an unreadable earlier run is unknown (blocked, retried); a readable crash is skipped"

# (4) run 43741742877 #1/#2: run 14 passed A, run 15 blocked A — completion times play no part
reset; run1 14 "review $A" success "$P"; run1 15 "review $A" failure "$P"
run1 16 "review $X" failure "$A"; run1 17 "review $N" success "$X"; run1 21 "review $F" skipped "$N"
expect "$A" any "pass 14 1" "(4)"
rp "$F" o/r "$P" || fail "(4) the first verdict of A (pass, run 14) did not stand over the later block"
reset; run1 14 "review $A" failure "$P"; run1 15 "review $A" success "$P"
run1 16 "review $X" failure "$A"; run1 17 "review $N" success "$X"; run1 21 "review $F" skipped "$N"
expect "$A" any "blocked 14 1" "(4) reversed"
if rp "$F" o/r "$P"; then fail "(4) a later pass (run 15) cleared A's first verdict (blocked, run 14)"; fi
# the listing order is irrelevant: the newest-first API order lists 15 before 14
reset; run1 15 "review $A" success "$P"; run1 14 "review $A" failure "$P"
expect "$A" any "blocked 14 1" "(4) listing order"
echo "ok (4) - the first run (by id) decides, both ways; no timestamps, no listing order"

# (5) attempts of one run: attempt 1 decides over attempt 2 (each attempt uploads its own attestation)
reset; listing 30 "review $A" 2 completed failure; attempt 30 1 2 success; attempt 30 2 2 failure; att 30 "$A" "$P" review 1; att 30 "$A" "$P" review 2
expect "$A" any "pass 30 1" "(5) pass then a blocked rerun"
reset; listing 30 "review $A" 2 completed success; attempt 30 1 2 failure; attempt 30 2 2 success; att 30 "$A" "$P" review 1; att 30 "$A" "$P" review 2
expect "$A" any "blocked 30 1" "(5) blocked then a passing rerun"
reset; listing 30 "review $A" 2 completed success; attempt 30 1 2 cancelled; attempt 30 2 2 success; att 30 "$A" "$P" review 2
expect "$A" any "pass 30 2" "(5) a cancelled attempt has no verdict"
# review of 9ce09a6e2 #3: a historical attempt never borrows another attempt's attestation. N's attempt 1 passed WITHOUT
# an upload; attempt 2 blocked and uploaded the broader range P..N → attempt 1 is an unattested pass (no verdict), N's
# verdict is attempt 2's block, and nothing above N is approved without its repair
reset; run1 11 "review $A" success "$P"; run1 12 "review $X" failure "$A"
listing 30 "review $N" 2 completed failure; attempt 30 1 2 success; attempt 30 2 2 failure; att 30 "$N" "$P" review 2
expect "$N" any "blocked 30 2" "(5) attempt 1 borrowed attempt 2's attestation"
# a legacy run-wide artifact (pins before the per-attempt upload) belongs to an attempt only in a single-attempt run
reset; listing 30 "review $A" 2 completed failure; attempt 30 1 2 success; attempt 30 2 2 failure; att 30 "$A" "$P"
expect "$A" any "blocked 30 2" "(5) a legacy artifact of a rerun run attested attempt 1"
reset; run1 30 "review $A" success "$P"
expect "$A" any "pass 30 1" "(5) a legacy artifact of a single-attempt run"
echo "ok (5) - attempts in order: the first attempt with a verdict decides; each attempt only with its own attestation"

# (6) unknown: an earlier run still running; unreadable jobs; unreadable attestation of a pass
reset; listing 30 "review $A" 1 in_progress; attempt 30 1 1 running; run1 31 "review $A" success "$P"
expect "$A" any "unknown 30 1" "(6) an earlier run still running"
reset; listing 30 "review $A" 2 completed success; attempt 30 2 2 success; att 30 "$A" "$P"   # attempt 1 unreadable
expect "$A" any "unknown 30 1" "(6) unreadable jobs of an earlier attempt"
reset; run1 30 "review $A" success "$P"; : > "$T/api/30.nozip"; run1 31 "review $A" failure "$P"
expect "$A" any "unknown 30 1" "(6) an unreadable attestation"
# a tests-only round whose trusted tests still run may still become the first verdict
reset; listing 30 "review $F" 1 in_progress; attempt 30 1 1 skipped; att 30 "$F" "$N" tests-only-fix
jq '.jobs[0].status = "in_progress" | .jobs[0].conclusion = null' "$T/api/30.jobs" > "$T/api/j" && mv "$T/api/j" "$T/api/30.jobs"
run1 31 "review $F" success "$N"
expect "$F" any "unknown 30 1" "(6) a tests-only round with its tests still running"
# a later run still running does not matter
reset; run1 30 "review $A" success "$P"; listing 31 "review $A" 1 in_progress; attempt 31 1 1 running
expect "$A" any "pass 30 1" "(6) a later running run"
echo "ok (6) - unreadable or unfinished earlier evidence is unknown; later runs never matter"

# (7) prior-findings.sh: the repair F of X gets X's FIRST blocked round (run 12), not a later rerun's (run 18)
reset; chain; run1 18 "review $X" failure "$A"
out=$(env_ bash "$ROOT/scripts/ci/prior-findings.sh" "$N" "$F" 2>/dev/null)
grep -q "finding of run 12 attempt 1" <<<"$out" || fail "(7) prior-findings did not attach run 12: $out"
grep -q "run 18" <<<"$out" && fail "(7) prior-findings attached the later run 18"
# dev-review-base.sh: X is a blocked repair target by its first verdict even when a later run passed it
reset; chain; run1 18 "review $X" success "$A"
env_ bash "$ROOT/scripts/ci/dev-review-base.sh" --only-fixes "$N" "$F" >/dev/null 2>&1 || fail "(7) F is no repair of X (first verdict blocked) after a later passing run"
echo "ok (7) - prior findings and repair targets follow the first verdict"

# (8) tralyx e964c6539 (11-15): a "merge main into dev" M whose tree IS its main parent's tree and that adds no commit of
# its own is covered from that main commit even though M's own review blocked (on main's code) — the dispatcher's
# dev_merge_only rule; nothing in M is dev's. A merge with a change of its own (evil merge) stays vetoed.
g checkout -q main; Q=$(c q "Q: main hotfix"); g update-ref refs/remotes/origin/main "$Q"
g checkout -q -b mo "$P"; g merge -q --no-ff -m "merge main into dev" "$Q"; M=$(g rev-parse HEAD)
Z=$(c z "Z: dev work on top")
reset; run1 40 "review $M" failure "$P"; run1 41 "review $Z" success "$M"
rp "$Z" o/r "$Q" || fail "(8) a merge-only commit (main's tree) with a blocked review stranded the dev head above it"
g checkout -q -b mo2 "$P"; g merge -q --no-ff --no-commit "$Q" >/dev/null 2>&1; echo evil >> "$T/src/q"; g add q; g commit -q -m "evil merge"; M2=$(g rev-parse HEAD)
Z2=$(c z "Z2"); reset; run1 42 "review $M2" failure "$P"; run1 43 "review $Z2" success "$M2"
if rp "$Z2" o/r "$Q"; then fail "(8) a blocked merge with a change of its own was covered"; fi
g checkout -q dev
echo "ok (8) - a merge-only commit identical to main's tree is covered; an evil merge's block still stands"
# (9) review of 9ce09a6e2 #1/#2: the review job classifying its own repair-only range is no evidence about itself —
# REVIEW_SELF_RUN (review.yml's range step) skips that unfinished attempt; another unfinished run still is unknown
reset; chain; listing 30 "review $F" 1 in_progress; attempt 30 1 1 running
env_ bash "$ROOT/scripts/ci/dev-review-base.sh" --only-fixes "$N" "$F" >/dev/null 2>&1 && fail "(9) control: an unfinished review of F (not this job) is unknown"
REVIEW_SELF_RUN="30 1" env_ bash "$ROOT/scripts/ci/dev-review-base.sh" --only-fixes "$N" "$F" >/dev/null 2>&1 \
  || fail "(9) the classifier vetoed its own repair-only range (its own running attempt)"
# Excluding the running attempt must preserve the decisive earlier attempt of the very same run.
reset; chain; listing 30 "review $F" 2 in_progress; attempt 30 1 2 failure; attempt 30 2 2 running
att 30 "$F" "$N" review 1
REVIEW_SELF_RUN="30 2" expect "$F" any "blocked 30 1" '(9) own historical attempt'
echo "ok (9) - a run is no evidence about itself; other unfinished runs still are unknown"

# (10) review of 9ce09a6e2 #7: a passing first verdict whose run did not conclude success (e.g. a failed status job) is
# not approved; (11) #5: the main verdict (REVIEW_PASSED_MODE=recheck, the dispatcher's completion gate) is the first
# "recheck" over the complete listing — a passing dev review of the same sha does not complete a blocked re-check
reset; chain; listing 21 "review $F" 1 completed failure; attempt 21 1 1 skipped; att 21 "$F" "$N" tests-only-fix
if rp "$F" o/r "$P"; then fail "(10) a run that concluded failure approved"; fi
reset   # 120 newer runs list first (newest first, as GitHub pages them): the blocked re-check 25 is on page 2
for i in $(seq 1 120); do printf '{"id":%s,"path":".github/workflows/review.yml","display_title":"review %040d","status":"completed","conclusion":"success","event":"workflow_run","head_branch":"main"}\n' $((90000 + i)) "$i" >> "$T/api/list"; done
chain; run1 21 "review $F" skipped "$N"; run1 25 "recheck $F" failure "$N"
if REVIEW_PASSED_MODE=recheck rp "$F" o/r; then fail "(11) the main verdict (blocked re-check 25, beyond 100 newer runs) completed"; fi
reset; run1 11 "review $A" success "$P"; run1 26 "recheck $A" success "$P"
REVIEW_PASSED_MODE=recheck rp "$A" o/r || fail "(11) control: a passing first re-check is the main verdict"
echo "ok (10)(11) - approval needs the run's success; the main verdict reads every page"
# (12) 746d20fe0 #6: both parents passed, M's own review blocked and its artifact was lost; V passed over M.
# The producer must widen past M rather than use structural parents to skip M; H's resulting review must approve.
g checkout -q -b lost-merge "$P"; L=$(c l left)
g checkout -q -b lost-right "$P"; R=$(c r right)
g checkout -q lost-merge; g merge -q --no-ff -m 'clean merge with its own blocked verdict' "$R"; BM=$(g rev-parse HEAD)
V=$(c v 'passing descendant'); H=$(c h 'new head')
reset; run1 51 "review $L" success "$P"; run1 52 "review $R" success "$P"
listing 53 "review $BM" 1 completed failure; attempt 53 1 1 failure   # deliberately no attestation
run1 54 "review $V" success "$BM"
base=$(env_ bash "$ROOT/scripts/ci/dev-review-base.sh" "$H" 2>/dev/null)
[ "$base" != "$V" ] || fail '(12) producer skipped the unrepaired blocked merge with missing proof'
run1 55 "review $H" success "$base"
rp "$H" o/r "$P" || fail '(12) the widened producer range still cannot approve H'
# A readable blocked link remains a producer base: its repair may arrive later. Only structural fallback is vetoed.
att 53 "$BM" "$P"
base=$(env_ bash "$ROOT/scripts/ci/dev-review-base.sh" "$H" 2>/dev/null)
[ "$base" = "$V" ] || fail '(12) readable producer proof of a blocked merge stopped being usable'
echo 'ok (12) - blocked merges without proof widen the produced range; readable producer links still work'
echo 'review first verdict: all checks passed'
