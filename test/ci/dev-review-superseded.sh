#!/usr/bin/env bash
# Tests-only fix rounds after a superseded block (owner 11-13: dev gets ONE review; a blocked head's repair lands on its
# trusted tests). tralyx 11-13/14: the dispatcher merged main into dev while dev heads were blocked; each merge head was
# reviewed (whole range again), blocked, and was superseded at once by the next merge — nobody ever wrote
# "Review-Fix-Of: <that merge>", so dev-review-base.sh --only-fixes saw a blocked, unrepaired review below every later
# range and no repair was ever a tests-only round again (9 full rounds of the same xsnipe commits).
# A blocked review of C is SUPERSEDED when a later completed review of a descendant D re-reviewed C's whole range (D's
# range base is at or below C's) and stands (passed, or blocked and repaired); then C needs no repair of its own.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
. "$(dirname "$0")/../../scripts/ci/test-review-fixtures.sh"   # T, FX, fake gh / curl, run, c, g, fail; cwd = $T/src
P=$(c prod); git update-ref refs/remotes/origin/main "$P"
g checkout -q -b dev
A=$(c "author work" '' devfile)
C=$(c "dev head, blocked, then superseded" '' devfile)
D=$(c "next dev head (re-reviews everything since main)" '' devfile2)
F=$(c "fix of D" "Review-Fix-Of: $D" devfile2)
of() { DEV_REVIEW_MAIN_REF=$P bash "$CI/dev-review-base.sh" --only-fixes "$@" 2>/dev/null; }
pass_log() { printf 'review-range: %s %s\n' "$2" "$3" > "$FX/log-$(($1 + 1000)).txt"; }   # a passed review's range line

# 1. C blocked (range P..C), D blocked re-reviewing P..D, F repairs D → C superseded: F is a tests-only round
reset; run 1 "review $C" success failure "$P" '' blocked; run 2 "review $D" success failure "$P" '' blocked
of "$D" "$F" || fail "a repair of D is not a tests-only round although D re-reviewed C's whole range"
echo 'superseded block: the repair of the newer round is a tests-only round'

# 2. D reviewed only C..D (its base is C): C's code was never reviewed again → still a full review
reset; run 1 "review $C" success failure "$P" '' blocked; run 2 "review $D" success failure "$C" '' blocked
if of "$D" "$F"; then fail "C superseded by a review that did not cover C's range"; fi
# D's base is ABOVE C's base (D reviewed A..D, C reviewed P..C) → not superseded either
reset; run 1 "review $C" success failure "$P" '' blocked; run 2 "review $D" success failure "$A" '' blocked
if of "$D" "$F"; then fail "C superseded by a review whose range started above C's"; fi
echo 'not superseded: a later review that did not re-review all of C'"'"'s range'

# 3. D blocked but NOT repaired (the fix names another sha) → C stays blocked
g checkout -q -b norep "$D"; F2=$(c "fix of C only" "Review-Fix-Of: $C" devfile)
reset; run 1 "review $C" success failure "$P" '' blocked; run 2 "review $D" success failure "$P" '' blocked
if of "$C" "$F2"; then fail "an unrepaired D superseded C"; fi
g checkout -q dev
echo 'not superseded: the covering review is itself blocked and unrepaired'

# 4. D PASSED re-reviewing P..D; E blocked above it, F3 repairs E → C superseded by D's pass
g checkout -q -b passed "$D"; E=$(c "E (blocked)" '' devfile3); F3=$(c "fix of E" "Review-Fix-Of: $E" devfile3)
reset; run 1 "review $C" success failure "$P" '' blocked; run 2 "review $D" success success "$P"; pass_log 2 "$P" "$D"
run 3 "review $E" success failure "$D" '' blocked
of "$E" "$F3" || fail "a passed review that re-reviewed C's range does not supersede C"
# … but not when the passed review's range began above C's base
reset; run 1 "review $C" success failure "$P" '' blocked; run 2 "review $D" success success "$C"; pass_log 2 "$C" "$D"
run 3 "review $E" success failure "$D" '' blocked
if of "$E" "$F3"; then fail "a passed review of C..D superseded C"; fi
g checkout -q dev
echo 'superseded by a passed review that covered its range; not by one that started above it'

# 5. (review of eff82b08e #1) a review on a side branch merged in later never saw C: it supersedes nothing, even with a
#    range base at or below C's and a repair
g checkout -q -b side "$P"; DS=$(c "side work, reviewed P..DS" '' sidefile); FDS=$(c "fix of DS" "Review-Fix-Of: $DS" sidefile)
g checkout -q -b withside "$C"; g merge -q --no-ff -m "merge side" side; MS=$(git rev-parse HEAD)
FS=$(c "fix of DS on dev" "Review-Fix-Of: $DS" sidefile)
reset; run 1 "review $C" success failure "$P" '' blocked; run 2 "review $DS" success failure "$P" '' blocked
if of "$MS" "$FS"; then fail "a side-branch review that never contained C superseded C"; fi
g checkout -q dev
echo 'not superseded: a review of a side branch that does not contain C'

# 7. (review of foxhole-backend b4d18dbbc #1) D passed re-reviewing P..D, then a standing revert of D (or of any commit
#    D's review saw above C) undoes what that review vouched for: D no longer supersedes C
g checkout -q -b reverted "$D"; RD=$(c "Revert \"next dev head\"" "This reverts commit $D." devfile2)
E7=$(c "E7 (blocked)" '' devfile3); F7=$(c "fix of E7" "Review-Fix-Of: $E7" devfile3)
reset; run 1 "review $C" success failure "$P" '' blocked; run 2 "review $D" success success "$P"; pass_log 2 "$P" "$D"
run 3 "review $E7" success failure "$RD" '' blocked
if of "$E7" "$F7"; then fail "a passed review of D superseded C although D was reverted since"; fi
g checkout -q dev
echo 'not superseded: a passed covering review whose change was reverted since'

# 6. a crash (no verdict) of D never supersedes
reset; run 1 "review $C" success failure "$P" '' blocked; run 2 "review $D" success failure "$P"   # no BLOCKED line: crash
if of "$D" "$F"; then fail "a crashed review of D superseded C"; fi
echo 'dev superseded-block checks passed'
