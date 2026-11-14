#!/usr/bin/env bash
# A Review-Fix-Of: trailer that names no ancestor (tralyx fd935e7c5, 11-14: a main hotfix named the dev sha 1de3ade46).
# hotfix-review-base.sh used to abort the range ("Review-Fix-Of must name an ancestor"), so every later main re-check
# failed before any review and main was stuck. Now:
#   1. the main range is computed, includes that commit, logs a warning, and the range step's kind is a full review;
#   2. every repair privilege still rejects the trailer on its own: repaired() (dev cover base, coverage links of
#      review-passed.sh), dev-review-base.sh --only-fixes (tests-only fix rounds), prior-findings.sh (the ledger that
#      narrows a re-review), each with a control that a real repair (an ancestor) still counts.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
. "$(dirname "$0")/../../scripts/ci/test-review-fixtures.sh"   # T, FX, fake gh / curl, run, c, g, fail; cwd = $T/src
valid=$'Loop: fixture\nThread: mcp:44444444-4444-4444-4444-444444444444\nVerify:\n- [x] offline fixture'

P=$(c prod "$valid")
g checkout -q -b dev
D1=$(c "dev one" "$valid" devfile)
S=$(c "dev head whose review blocked" "$valid" devfile)
g checkout -q main
M1=$(c "hotfix one" "Hotfix: one"$'\n'"$valid" mainfile)
# the culprit: a main hotfix that names the dev sha S, which is NOT its ancestor
H=$(c "hotfix naming a dev sha" "Hotfix: two"$'\n'"Review-Fix-Of: $S"$'\n'"$valid" mainfile)
H2=$(c "hotfix three" "Hotfix: three"$'\n'"$valid" mainfile)
git update-ref refs/remotes/origin/main "$H2"
reset
run 1 "review $S" success failure "$P" '' blocked
run 2 "recheck $M1" success success "$P"

# 1. main: hotfix-review-base.sh computes the base, keeps H in the range, warns
base=$(bash "$CI/hotfix-review-base.sh" HEAD 2>"$T/err") || fail "hotfix-review-base.sh aborted on a non-ancestor Review-Fix-Of: $(cat "$T/err")"
[ "$base" = "$M1" ] || fail "main base is ${base:0:9}, not the last completed review ${M1:0:9}"
git rev-list "$base..HEAD" | grep -qx "$H" || fail "the commit with the non-ancestor trailer left the range"
grep -q "warning: ${H:0:12} carries Review-Fix-Of: ${S:0:12}, which is not its ancestor" "$T/err" || fail "no warning: $(cat "$T/err")"
# an unknown sha (not even in this clone) is ignored the same way
B=$(c "bogus" "Hotfix: bogus"$'\n'"Review-Fix-Of: $(printf 'a%.0s' $(seq 40))"$'\n'"$valid" mainfile)
git update-ref refs/remotes/origin/main "$B"
[ "$(bash "$CI/hotfix-review-base.sh" HEAD 2>/dev/null)" = "$M1" ] || fail "an unknown Review-Fix-Of: sha stopped the range"
g reset -q --hard "$H2"; git update-ref refs/remotes/origin/main "$H2"
# the workflow's own range step (extracted from review.yml) on the default branch: completes, kind = full review
mkdir -p "$T/job/.sheepdog/scripts"; ln -s "$CI" "$T/job/.sheepdog/scripts/ci"
python3 - "$ROOT/.github/workflows/review.yml" "$T/job/range-main.sh" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
st = next(s for s in w["jobs"]["review"]["steps"] if s.get("name") == "Reviewed range")
open(sys.argv[2], "w").write("HEAD_BRANCH=main\n" + st["run"])
PY
git clone -q "$T/src" "$T/job/candidate"; git -C "$T/job/candidate" checkout -q --detach "$H2"
git -C "$T/job/candidate" update-ref refs/remotes/origin/main "$H2"
( cd "$T/job/candidate" && GITHUB_ENV=$T/job/env GITHUB_OUTPUT=$T/job/out MAIN_BRANCH=main DEV_BRANCH=dev REVIEW_DEFAULT_BRANCH=main \
    bash -e -o pipefail "$T/job/range-main.sh" > "$T/job/log" 2>&1 ) || fail "the Reviewed range step failed: $(tail -5 "$T/job/log")"
grep -qx "kind=review" "$T/job/out" || fail "main range kind: $(cat "$T/job/out")"
grep -qx "review-range: $M1 $H2" "$T/job/log" || fail "range line: $(grep review-range "$T/job/log")"
grep -qx "REVIEW_BASE=$M1" "$T/job/env" || fail "REVIEW_BASE not exported"
echo 'main range: computed past a non-ancestor Review-Fix-Of:, commit kept, warning logged, full review'

# 2. the privilege paths. main (with H) reaches dev by a clean merge: H now sits in S..dev, but does not contain S.
g checkout -q dev; g merge -q --no-ff -m "merge main into dev" -m "$valid" main; DM=$(git rev-parse HEAD)
. "$CI/review-repair.sh"
if repaired "$S" "$DM"; then fail "repaired(): a non-ancestor Review-Fix-Of: repaired the blocked dev review"; fi
cover=$(DEV_REVIEW_MAIN_REF=$H2 bash "$CI/dev-review-base.sh" "$DM" 2>"$T/err")
# Check the coverage obligation, not diagnostic wording: this suite also runs
# against the older self-review pin, which reports an unrepaired block differently.
[ "$cover" = "$P" ] || fail "dev cover base: expected the blocked review's base $P, got $cover: $(cat "$T/err")"
# review-passed.sh's coverage link: the blocked review of S is no link while only H "repairs" it
review_api() { curl -fsSL "https://api.github.com/repos/$REPO/$1"; }
. "$CI/review-runs.sh"; . "$CI/review-coverage.sh"
if review_link 1 "$S" "$P" "$DM" 0; then fail "coverage: a blocked review repaired only by a non-ancestor trailer is a link"; fi
# control: a real repair of S (an ancestor) counts everywhere
F1=$(c "fix of S" "Review-Fix-Of: $S"$'\n'"$valid" devfile)
repaired "$S" "$F1" || fail "control: a real repair is not counted"
review_link 1 "$S" "$P" "$F1" 0 || fail "control: the repaired blocked review is no coverage link"
DEV_REVIEW_MAIN_REF=$H2 bash "$CI/dev-review-base.sh" --only-fixes "$S" "$F1" 2>/dev/null || fail "control: a range of a real repair (+ a clean main merge) is not a tests-only round"
# --only-fixes: a dev commit naming a blocked sha that is not its ancestor is no fix → full review
g checkout -q -b side "$P"; X=$(c "side work, reviewed and blocked" "$valid" sidefile); g checkout -q dev
run 3 "review $X" success failure "$P" '' blocked
F2=$(c "claims to fix X" "Review-Fix-Of: $X"$'\n'"$valid" devfile)
if DEV_REVIEW_MAIN_REF=$H2 bash "$CI/dev-review-base.sh" --only-fixes "$S" "$F2" 2>/dev/null; then fail "--only-fixes: a non-ancestor Review-Fix-Of: made a tests-only round"; fi
echo 'privileges: repaired / coverage link / --only-fixes reject a non-ancestor trailer; a real repair still counts'

# 3. prior-findings.sh: the ledger never attaches the blocked round of a non-ancestor (it would tell the reviewer that
#    S's ancestors were reviewed then); a real repair's round is attached
out=$(bash "$CI/prior-findings.sh" "$M1" "$H2" 2>"$T/err")
if grep -q "the review that blocked $S" <<<"$out"; then fail "prior-findings: a non-ancestor trailer attached S's round"; fi
grep -q "${H:0:12} names ${S:0:12}, not its ancestor" "$T/err" || fail "prior-findings: no note: $(cat "$T/err")"
out=$(bash "$CI/prior-findings.sh" "$S" "$F1" 2>/dev/null)
grep -q "^== the review that blocked $S (run 1):" <<<"$out" || fail "control: a real repair's previous findings are missing"
echo 'ledger: only ancestors'"'"' rounds are attached'
echo 'non-ancestor Review-Fix-Of: checks passed'
