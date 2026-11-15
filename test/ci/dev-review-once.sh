#!/usr/bin/env bash
# The owner's dev rule (11-15): on dev every new commit is reviewed EXACTLY ONCE. A blocked commit is not reviewed again
# by the next push's review; its Review-Fix-Of: repair lands on green trusted tests (a tests-only round); commits that
# reached dev through a main→dev merge are main's and appear in no dev review range or diff. Approval of a dev sha needs
# the coverage chain from main / prod to it, so a blocked commit below a passing one lands only with its repair.
#   (a) a blocked commit is not re-reviewed by the next dev push's review
#   (b) commits from a main→dev merge never appear in a dev review's commit list or diff (mainside attested)
#   (c) a repair-only round is a tests-only round (also with a main merge in it)
#   (d) coverage / approval from prod to the head works across a blocked + repaired commit and across main merges
#   (e) a new commit after a blocked one is reviewed alone
#   (f) the range waits for a still-running review of the nearest ancestor instead of reviewing its commits twice
#   (g) the devfix landing check (review-covered.sh) needs the chain below the blocked sha
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
ROOT=$PWD
BASE_SH=$ROOT/scripts/ci/dev-review-base.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q -b main "$T/src"
g() { git -C "$T/src" -c user.name=t -c user.email=t@t "$@"; }
c() { echo "$RANDOM $2" >> "$T/src/$1"; g add "$1"; g commit -q -m "$2" ${3:+-m "$3"}; g rev-parse HEAD; }
P=$(c f production)
g update-ref refs/remotes/origin/main "$P"
g checkout -q -b dev
A=$(c a "A (passed)")
X=$(c x "X (its review blocked)")
N=$(c n "N (new work after the block)")
F=$(c x "F: repair of X" "Review-Fix-Of: $X")

# fake GitHub API (curl for dev-review-base.sh, gh for review-passed.sh / review-covered.sh): one file per run under $T/api
mkdir -p "$T/bin" "$T/api"
: > "$T/api/list"
run() { # run <id> <title> <blocking step: success|failure|skipped(tests-only)|running> <attested base> [<mainside>]
  local st=$3 jst=completed jc
  case "$st" in success|skipped) jc=success ;; running) jst=in_progress; jc=null; st=null ;; *) jc=failure ;; esac
  printf '{"id":%s,"path":".github/workflows/review.yml","display_title":"%s","status":"completed","conclusion":"%s","event":"workflow_run","head_branch":"main"}\n' "$1" "$2" "$([ "$jc" = success ] && echo success || echo failure)" >> "$T/api/list"
  printf '{"jobs":[{"name":"tests","status":"completed","conclusion":"success","steps":[]},{"name":"review","id":%s,"status":"%s","conclusion":%s,"steps":[{"name":"Review (blocking)","conclusion":%s}]}]}\n' \
    "$(($1 + 1000))" "$jst" "$([ "$jc" = null ] && echo null || echo "\"$jc\"")" "$([ "$st" = null ] && echo null || echo "\"$st\"")" > "$T/api/$1.jobs"
  { echo "2026-11-15T00:00:00.0Z review-range: $4 ${2#* }"
    [ "$3" = failure ] && echo "2026-11-15T00:00:02.0Z review-gate: BLOCKED #1 regression [should]: x"; true; } > "$T/api/$(($1 + 1000)).log"
  local kind=review; [ "$3" = skipped ] && kind=tests-only-fix
  jq -nc --arg h "${2#* }" --arg b "$4" --arg k "$kind" --arg m "$P" --arg ms "${5:-}" \
    '{head: $h, base: $b, kind: $k, main: $m} + (if $ms == "" then {} else {mainside: $ms} end)' > "$T/api/review-attestation.json"
  python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.write(sys.argv[2],"review-attestation.json"); z.close()' "$T/api/$1.zip" "$T/api/review-attestation.json"
}
reset_runs() { : > "$T/api/list"; rm -f "$T/api/"*.jobs "$T/api/"*.zip "$T/api/"*.log; }
cat > "$T/bin/page" <<PAGE
#!/usr/bin/env bash
p=\$(sed -nE 's/.*[?&]page=([0-9]+).*/\1/p' <<<"\$1"); p=\${p:-1}
st=\$(sed -nE 's/.*[?&]status=([a-z]+).*/\1/p' <<<"\$1")
sed -n "\$(( (p - 1) * 100 + 1 )),\$(( p * 100 ))p" "$T/api/list" | jq -s --arg st "\$st" '{workflow_runs: [.[] | select(\$st == "" or \$st == "completed" or .conclusion == \$st)]}'
PAGE
cat > "$T/bin/curl" <<CURL
#!/usr/bin/env bash
u=\${@: -1}
case "\$u" in
  *workflows/review.yml/runs*) "$T/bin/page" "\$u" ;;
  */actions/runs/*/jobs) id=\${u##*runs/}; id=\${id%%/*}; cat "$T/api/\$id.jobs" 2>/dev/null || exit 22 ;;
  */actions/jobs/*/logs) id=\${u%/logs}; cat "$T/api/\${id##*/}.log" 2>/dev/null || exit 22 ;;
  */actions/runs/*/artifacts) id=\${u##*runs/}; id=\${id%%/*}; if [ -e "$T/api/\$id.zip" ]; then echo "{\"artifacts\":[{\"name\":\"review-attestation\",\"id\":\$id}]}"; else echo '{"artifacts":[]}'; fi ;;
  */actions/artifacts/*/zip) id=\${u%/zip}; cat "$T/api/\${id##*/}.zip" ;;
  *) exit 22 ;;
esac
CURL
cat > "$T/bin/gh" <<GH
#!/usr/bin/env bash
[ "\$1" = api ] || exit 1
url=\$2; q=""; [ "\${3:-}" = -q ] && q=\$4
url=\${url#repos/o/r/}
case "\$url" in
  *workflows/review.yml/runs*) j=\$("$T/bin/page" "\$url") ;;
  */runs/*/jobs) id=\${url##*runs/}; j=\$(cat "$T/api/\${id%%/*}.jobs") ;;
  */jobs/*/logs) id=\${url%/logs}; cat "$T/api/\${id##*/}.log" 2>/dev/null; exit ;;
  */runs/*/artifacts) id=\${url##*runs/}; id=\${id%%/*}; if [ -e "$T/api/\$id.zip" ]; then j="{\"artifacts\":[{\"name\":\"review-attestation\",\"id\":\$id}]}"; else j='{"artifacts":[]}'; fi ;;
  */artifacts/*/zip) id=\${url%/zip}; cat "$T/api/\${id##*/}.zip"; exit ;;
  *) exit 1 ;;
esac
if [ -n "\$q" ]; then jq -r "\$q" <<<"\$j"; else echo "\$j"; fi
GH
chmod +x "$T/bin/curl" "$T/bin/gh" "$T/bin/page"
base() { (cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r REVIEW_BASE_WAIT_SEC=${WAIT:-0} REVIEW_BASE_POLL_SEC=1 bash "$BASE_SH" "$@" 2>/dev/null); }
rp() { (cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r bash "$ROOT/scripts/ci/review-passed.sh" "$@" >/dev/null 2>&1); }

# A passed (P..A), X blocked (A..X), N passed (X..N), F a tests-only round (N..F)
runs_dev() { run 11 "review $A" success "$P"; run 12 "review $X" failure "$A"; run 13 "review $N" success "$X"; }

# (a) + (e): the review of N starts at X although X blocked and is not repaired: X is not reviewed again, N alone is
reset_runs; run 11 "review $A" success "$P"; run 12 "review $X" failure "$A"
[ "$(base "$N")" = "$X" ] || fail "(a) N's range starts at $(base "$N"), not at the blocked X"
[ "$(base --diff "$X" "$N")" = "$X" ] || fail "(e) no main side: the diff base is the cover base"
[ "$(g rev-list "$X..$N")" = "$N" ] || fail "(e) N is not reviewed alone"
if base --only-fixes "$X" "$N"; then fail "(e) new work after a block is a tests-only round"; fi
# … and a newer blocked review is a base too: the next push after a blocked N reviews only what came after N
reset_runs; run 11 "review $A" success "$P"; run 12 "review $X" failure "$A"; run 13 "review $N" failure "$X"
[ "$(base "$F")" = "$N" ] || fail "(a) F's range starts at $(base "$F"), not at the blocked N"
echo "ok (a)(e) - the next review starts at the last completed review, blocked or not; a new commit is reviewed alone"

# (c): a repair-only round is tests-only
reset_runs; runs_dev
[ "$(base "$F")" = "$N" ] || fail "(c) F's range starts at $(base "$F")"
base --only-fixes "$N" "$F" || fail "(c) the repair-only round N..F is not tests-only"
# a repair of a review that never blocked is no repair: reviewed
G0=$(g rev-parse HEAD); g checkout -q -b norep "$N"; NR=$(c n "names A" "Review-Fix-Of: $A")
if base --only-fixes "$N" "$NR"; then fail "(c) a Review-Fix-Of: naming a passed review was tests-only"; fi
g checkout -q dev
echo "ok (c) - a round of only repairs of blocked reviews is tests-only"

# (d) approval needs the chain: N passed but X below it is blocked and unrepaired → N is not approvable from P; F is
run 14 "review $F" skipped "$N"
if rp "$N" o/r "$P"; then fail "(d) N was approved with the blocked X below it unrepaired"; fi
rp "$F" o/r "$P" || fail "(d) the tests-only F (X repaired) is not approved from P"
# merge-branch.sh (the train's landing) refuses N and lands F
git clone -q --bare "$T/src" "$T/origin.git"; git -C "$T/origin.git" update-ref refs/heads/main "$P"; git -C "$T/origin.git" update-ref refs/heads/dev "$F"
git clone -q "$T/origin.git" "$T/work"
if (cd "$T/work" && PATH=$T/bin:$PATH REPO=o/r GH_TOKEN=x bash "$ROOT/scripts/ci/merge-branch.sh" dev "$N" >/dev/null 2>&1); then fail "(d) merge-branch.sh landed N over the unrepaired X"; fi
[ "$(git -C "$T/origin.git" rev-parse refs/heads/main)" = "$P" ] || fail "(d) main moved"
(cd "$T/work" && PATH=$T/bin:$PATH REPO=o/r GH_TOKEN=x bash "$ROOT/scripts/ci/merge-branch.sh" dev "$F" >/dev/null 2>&1) || fail "(d) merge-branch.sh did not land F"
[ "$(git -C "$T/origin.git" rev-parse refs/heads/main)" = "$F" ] || fail "(d) main is not F"
# a reviewed head above a tests-only round main has not re-checked: approved (the round is a verified link), reported
# in REVIEW_FIXES_OUT, and merge-branch.sh lands it only after the fix itself (whose landing main re-checks)
git -C "$T/origin.git" update-ref refs/heads/main "$P"
g checkout -q -b above "$F"; N3=$(c n3 "N3 (after the repair)"); g checkout -q dev
git -C "$T/src" push -q "$T/origin.git" "$N3:refs/heads/dev"
run 18 "review $N3" success "$F"
(cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r REVIEW_FIXES_OUT=$T/fixes bash "$ROOT/scripts/ci/review-passed.sh" "$N3" o/r "$P" >/dev/null 2>&1) || fail "(d) N3 not approved through the tests-only link F"
[ "$(cat "$T/fixes")" = "$F" ] || fail "(d) the tests-only link F is not reported: $(cat "$T/fixes")"
mb() { (cd "$T/work" && PATH=$T/bin:$PATH REPO=o/r GH_TOKEN=x bash "$ROOT/scripts/ci/merge-branch.sh" dev "$1" >"$T/mb.out" 2>&1); }
if mb "$N3"; then fail "(d) merge-branch.sh landed N3 before main re-checks the fix F"; fi
grep -q "land the fix first" "$T/mb.out" || fail "(d) unexpected refusal: $(cat "$T/mb.out")"
mb "$F" || fail "(d) F did not land: $(cat "$T/mb.out")"
mb "$N3" || fail "(d) N3 did not land after F: $(cat "$T/mb.out")"
[ "$(git -C "$T/origin.git" rev-parse refs/heads/main)" = "$N3" ] || fail "(d) main is not N3"
# liveness: X and N both blocked; F repairs X (tests-only), FN repairs N (tests-only, its range starts at F)
reset_runs; run 11 "review $A" success "$P"; run 12 "review $X" failure "$A"; run 13 "review $N" failure "$X"; run 14 "review $F" skipped "$N"
g checkout -q -b fn "$F"; FN=$(c n "FN: repair of N" "Review-Fix-Of: $N"); g checkout -q dev
[ "$(base "$FN")" = "$F" ] || fail "(d) FN's range does not start at the tests-only round F"
base --only-fixes "$F" "$FN" || fail "(d) FN is not a tests-only round"
run 19 "review $FN" skipped "$F"
if rp "$F" o/r "$P"; then fail "(d) F approved with the blocked N below it unrepaired"; fi
rp "$FN" o/r "$P" || fail "(d) FN (every block repaired, through the tests-only link F) is not approved"
echo "ok (d) - approval follows the chain: a blocked commit lands only with its repair; unreviewed fixes land re-checked"

# (b) main moves (F landed, then a hotfix H, each re-checked); dev goes on (D1, reviewed from F), main is merged into
# dev (G), D2 is new dev work
D1=$(c d1 "D1 (dev work, reviewed)")
g update-ref refs/heads/main "$F"; g checkout -q main
H=$(c h "hotfix H on main" "Hotfix: h"); g update-ref refs/remotes/origin/main "$H"
g checkout -q dev; g merge -q --no-ff -m "merge main into dev" main; G=$(g rev-parse HEAD)
D2=$(c d "D2 (new dev work)")
runs_d1() { runs_dev; run 14 "review $F" skipped "$N"; run 17 "review $D1" success "$F"; }
reset_runs; runs_d1
[ "$(base "$D2")" = "$D1" ] || fail "(b) D2's range starts at $(base "$D2"), not at D1"
[ "$(base --mainside "$D1" "$D2")" = "$H" ] || fail "(b) the main side of D1..D2 is not H"
V=$(base --diff "$D1" "$D2")
[ "$V" != "$D1" ] || fail "(b) the diff base did not exclude main's side"
[ "$(g diff --name-only "$V" "$D2")" = d ] || fail "(b) the diff shows more than D2's change: $(g diff --name-only "$V" "$D2" | tr '\n' ' ')"
[ "$(g rev-list --no-merges "$V..$D2")" = "$D2" ] || fail "(b) the commit list is not D2 alone"
[ -z "$(git -C "$T/origin.git" cat-file -t "$V" 2>/dev/null)" ] || fail "(b) the virtual base is published"
[ "$(base --diff "$D1" "$D2")" = "$V" ] || fail "(b) the virtual base is not deterministic"
# the merge-only push G: nothing dev-side → the diff base is G itself (review-gate: empty range)
[ "$(base --diff "$D1" "$G")" = "$G" ] || fail "(b) the merge-only round G has something to review"
# the tests-only round F already on main: the walk stops at main (everything below H is main's)
reset_runs; runs_dev; run 14 "review $F" skipped "$N"
[ "$(base "$G")" = "$D1" ] || [ "$(base "$G")" = "$H" ] || fail "(b) G's range"
reset_runs; runs_d1
[ -z "$(base --mainside "$G" "$D2")" ] || fail "(b) a main side below the cover base was reported"
# review.yml's range step on D2: review-range = the published cover base, the log and the attestation without H
mkdir -p "$T/.sheepdog"; ln -s "$ROOT/scripts" "$T/.sheepdog/scripts"
python3 - "$T" <<'PY'
import sys, yaml
w = yaml.safe_load(open(".github/workflows/review.yml"))
steps = w["jobs"]["review"]["steps"]
step = lambda n: next(s for s in steps if (s.get("name") or "").startswith(n))
env = "HEAD_BRANCH=dev MAIN_BRANCH=main DEV_BRANCH=dev REVIEW_DEFAULT_BRANCH=main REVIEW_BASE_WAIT_SEC=0\n"
open(sys.argv[1] + "/range.sh", "w").write(env + step("Reviewed range")["run"])
open(sys.argv[1] + "/attest.sh", "w").write('KIND=$RANGE_KIND\n' + step("Attestation")["run"])
rev = step("Review (blocking")["run"]
if '--base "$REVIEW_DIFF_BASE"' not in rev: sys.exit("the reviewer does not diff against REVIEW_DIFF_BASE")
PY
git clone -q "$T/src" "$T/candidate"; git -C "$T/candidate" checkout -q --detach "$D2"
export GITHUB_ENV=$T/env GITHUB_OUTPUT=$T/out; : > "$GITHUB_ENV"; : > "$GITHUB_OUTPUT"
out=$(cd "$T/candidate" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r bash -e "$T/range.sh" 2>&1) || fail "range step: $out"
grep -qx "review-range: $D1 $D2" <<<"$out" || fail "(b) range line: $out"
grep -q "${H:0:7}" <<<"$(grep -v '^dev review:' <<<"$out")" && fail "(b) main's H is listed in the dev range: $out"
grep -qx 'kind=review' "$GITHUB_OUTPUT" || fail "(b) D2 is not a full review"
grep -qx "REVIEW_MAINSIDE=$H" "$GITHUB_ENV" || fail "(b) mainside not exported"
(cd "$T/candidate" && set -a && . "$GITHUB_ENV" && set +a && RANGE_KIND=review bash -e "$T/attest.sh" >/dev/null)
[ "$(jq -r .base "$T/attest/review-attestation.json")" = "$D1" ] || fail "(b) attested base"
[ "$(jq -r .mainside "$T/attest/review-attestation.json")" = "$H" ] || fail "(b) attested mainside"
rd=$(sed -n 's/^REVIEW_DIFF_BASE=//p' "$GITHUB_ENV"); [ "$(git -C "$T/candidate" diff --name-only "$rd" HEAD)" = d ] || fail "(b) REVIEW_DIFF_BASE diff"
echo "ok (b) - main→dev merges contribute nothing to a dev range: virtual diff base, mainside attested"

# (c) with a main merge in the round: X2 blocked after the merge, a repair of it → tests-only
g checkout -q -b c2 "$D2"; X2=$(c x2 "X2 (blocked)"); F2=$(c x2 "repair of X2" "Review-Fix-Of: $X2")
run 15 "review $D2" success "$D1" "$H"; run 16 "review $X2" failure "$D2"
[ "$(base "$F2")" = "$X2" ] || fail "(c) F2's range"
(cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r DEV_REVIEW_MAIN_REF=$H bash "$BASE_SH" --only-fixes "$D2" "$F2" >/dev/null 2>&1) \
  && fail "(c) a range with the unreviewed X2 was tests-only"
g checkout -q dev
echo "ok (c) - repair rounds above main merges"

# (d) across the main merge: D2 from prod P — F's tests-only round is a verified link; H, the main side D2 did not
# review, needs main's own re-check
if rp "$D2" o/r "$P"; then fail "(d) D2 deployable with main's H never reviewed (mainside)"; fi
run 22 "recheck $H" success "$F"
rp "$D2" o/r "$P" || fail "(d) D2 not deployable with every link present"
# the train's anchor (the main commit D2 contains) covers main's side directly
reset_runs; runs_d1; run 15 "review $D2" success "$D1" "$H"
rp "$D2" o/r "$H" || fail "(d) D2 not approvable from main H"
# a mainside that is not an ancestor of the head is refused
reset_runs; runs_d1; run 15 "review $D2" success "$D1" "$X2"
if rp "$D2" o/r "$H"; then fail "(d) a forged mainside was accepted"; fi
echo "ok (d) - coverage across blocked + repaired commits and main merges"

# (f) the nearest ancestor's review is still running: wait for it, then start there (main back at P for (f)/(g))
g update-ref refs/remotes/origin/main "$P"
reset_runs; run 11 "review $A" success "$P"; run 12 "review $X" running "$A"
[ "$(WAIT=0 base "$N")" = "$A" ] || fail "(f) without waiting, N's range starts at A"
( sleep 2; run 12 "review $X" failure "$A" ) &
[ "$(WAIT=20 base "$N")" = "$X" ] || fail "(f) N's range did not wait for X's running review"
wait
echo "ok (f) - a running ancestor review is awaited, not repeated"

# (g) devfix landing: X + its fix lands only when the chain below X is covered (W blocked and unrepaired → not)
cov() { (cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x bash "$ROOT/scripts/ci/review-covered.sh" "$1" "$2" "$3" o/r >/dev/null 2>&1); }
g checkout -q -b fixbranch "$X"; FX=$(c x "devfix of X" "Review-Fix-Of: $X")
reset_runs; run 11 "review $A" success "$P"; run 12 "review $X" failure "$A"
cov "$X" "$P" "$FX" || fail "(g) X + its fix not covered"
reset_runs; run 11 "review $A" failure "$P"; run 12 "review $X" failure "$A"
if cov "$X" "$P" "$FX"; then fail "(g) X + its fix covered with the blocked A below it unrepaired"; fi
if cov "$X" "$P" "$X"; then fail "(g) blocked X covered without its fix"; fi
g checkout -q dev
echo "ok (g) - devfix landing needs the chain below the blocked sha"
echo 'dev review once: all checks passed'
