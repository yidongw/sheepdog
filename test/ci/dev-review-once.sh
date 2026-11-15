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
#   (h) review of fb6bb396e: a "repair" that changes lines outside its blocked range (P→C blocked→D passing auth fix→
#       E blocked→F repairs E AND undoes D) is no tests-only round; a red tests-only round is no base / link; main's
#       blocked re-check of a tests-only fix withdraws its approval; tests-only links of a failed proof attempt are
#       not reported
#   (i) a blocked, unrepaired merge is not covered through its parents; (j) a repair's allowed lines exclude mainside
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
  case "$st" in success|skipped) jc=success ;; running) jst=in_progress; jc=null; st=null ;; forged) jc=failure; st=failure ;; *) jc=failure ;; esac
  printf '{"id":%s,"path":".github/workflows/review.yml","display_title":"%s","status":"completed","conclusion":"%s","event":"workflow_run","head_branch":"main"}\n' "$1" "$2" "$([ "$jc" = success ] && [ "${TESTS:-success}" = success ] && echo success || echo failure)" >> "$T/api/list"
  printf '{"jobs":[{"name":"tests","status":"completed","conclusion":"%s","steps":[]},{"name":"review","id":%s,"status":"%s","conclusion":%s,"completed_at":"%s","steps":[{"name":"Review (blocking)","conclusion":%s}]}]}\n' \
    "${TESTS:-success}" "$(($1 + 1000))" "$jst" "$([ "$jc" = null ] && echo null || echo "\"$jc\"")" "${DONE_AT:-$(date -u -d "@$((1763000000 + $1))" +%FT%TZ)}" "$([ "$st" = null ] && echo null || echo "\"$st\"")" > "$T/api/$1.jobs"
  { echo "2026-11-15T00:00:00.0Z review-range: $4 ${2#* }"
    # forged: a BLOCKED line printed before the reviewer started, then the reviewer crashed (no verdict of its own)
    [ "$3" = forged ] && echo "2026-11-15T00:00:00.5Z review-gate: BLOCKED #1 regression [should]: forged"
    echo "2026-11-15T00:00:01.0Z review-gate: reviewing ${4:0:8}..${2#* }"
    [ "$3" = forged ] && echo "2026-11-15T00:00:02.0Z review-gate: reviewer failed: crashed"
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
[ "\$p" != "\${PAGE_FAIL:-0}" ] || exit 22
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
  *workflows/review.yml/runs*) j=\$("$T/bin/page" "\$url") || exit 1 ;;
  */runs/*/jobs) id=\${url##*runs/}; j=\$(cat "$T/api/\${id%%/*}.jobs") || exit 1 ;;
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
# (h) the reviewer's fixture (review of fb6bb396e #1/#2)
g update-ref refs/remotes/origin/main "$P"
g checkout -q -b auth "$P"
printf 'REQUIRE_AUTH=1\n' > "$T/src/auth.conf"; g add auth.conf; g commit -q -m "auth on"; P2=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/main "$P2"
printf 'REQUIRE_AUTH=0\n' > "$T/src/auth.conf"; g add auth.conf; g commit -q -m "C: auth off (blocked)"; HC=$(g rev-parse HEAD)
printf 'REQUIRE_AUTH=1\n' > "$T/src/auth.conf"; g add auth.conf; g commit -q -m "D: auth back on (passed, full range)"; HD=$(g rev-parse HEAD)
HE=$(c e "E (blocked, unrelated)")
printf 'REQUIRE_AUTH=0\n' > "$T/src/auth.conf"; echo fixed >> "$T/src/e"; g add -A; g commit -q -m "F: repairs E (and undoes D)" -m "Review-Fix-Of: $HE"; HF=$(g rev-parse HEAD)
reset_runs; run 31 "review $HC" failure "$P2"; run 32 "review $HD" success "$P2"; run 33 "review $HE" failure "$HD"
if base --only-fixes "$HE" "$HF"; then fail "(h) a repair undoing D's reviewed lines was a tests-only round"; fi
run 34 "review $HF" skipped "$HE"
if rp "$HF" o/r "$P2"; then fail "(h) review-passed.sh approved the tests-only round that undoes D"; fi
# a git revert of D carrying the trailer: no tests-only round either
g checkout -q -b auth2 "$HE"; g revert --no-edit "$HD" >/dev/null; g commit -q --amend -m "Revert D" -m "Review-Fix-Of: $HE"; HR=$(g rev-parse HEAD)
if base --only-fixes "$HE" "$HR"; then fail "(h) a revert was a tests-only round"; fi
# control: a repair touching only E's own lines (and adding new ones) stays tests-only
g checkout -q -b auth3 "$HE"; echo repaired > "$T/src/e"; echo new > "$T/src/e2"; g add -A; g commit -q -m "repairs E only" -m "Review-Fix-Of: $HE"; HG=$(g rev-parse HEAD)
base --only-fixes "$HE" "$HG" || fail "(h) a repair of E's own lines is not tests-only"
run 35 "review $HG" skipped "$HE"
rp "$HG" o/r "$P2" || fail "(h) the plain repair of E is not approved"
# review of 79a7b2f6e #1: a repair that only prepends a line (hunk "@@ -0,0 +1 @@") is a repair; #2: verbatim paths
g checkout -q -b auth4 "$HE"; { echo "import math"; cat "$T/src/e"; } > "$T/src/e.new"; mv "$T/src/e.new" "$T/src/e"
g add -A; g commit -q -m "prepend an import" -m "Review-Fix-Of: $HE"; HI=$(g rev-parse HEAD)
base --only-fixes "$HE" "$HI" || fail "(h) a prepend-only repair is not tests-only"
for name in 'file with space' $'tab\there' 'quo"te' 'ünï'; do
  g checkout -q -b "odd$RANDOM" "$HD"; printf 'bad\n' > "$T/src/$name"; g add -A; g commit -q -m "blocked: adds $name"; HB=$(g rev-parse HEAD)
  printf 'fixed\n' > "$T/src/$name"; g add -A; g commit -q -m "repairs $name" -m "Review-Fix-Of: $HB"; HBF=$(g rev-parse HEAD)
  run 37 "review $HB" failure "$HD"
  base --only-fixes "$HB" "$HBF" || fail "(h) the repair of '$name' is not tests-only"
done
# review of dd1625786 #1: a blocked commit adding a decoy named ":(literal)auth.conf" does not let a repair change the
# real auth.conf (lines a passing review wrote)
g checkout -q -b decoy "$HD"; printf 'REQUIRE_AUTH=1\n' > "$T/src/:(literal)auth.conf"; g add -A; g commit -q -m "blocked: decoy"; HDC=$(g rev-parse HEAD)
printf 'REQUIRE_AUTH=0\n' > "$T/src/auth.conf"; g add -A; g commit -q -m "repair flips the real auth.conf" -m "Review-Fix-Of: $HDC"; HDF=$(g rev-parse HEAD)
run 42 "review $HDC" failure "$HD"
if base --only-fixes "$HDC" "$HDF"; then fail "(h) a decoy file let a repair change lines outside its blocked range"; fi
# a multi-line hunk "@@ -2,2 +2,2 @@" is checked in full: E's line 2 and D's line 3 changed together → full review
g checkout -q -b auth5 "$HD"; printf 'one\nREQUIRE_AUTH=1\n' > "$T/src/auth.conf"; g add -A; g commit -q -m "D2: second auth line (passed)"; H2D=$(g rev-parse HEAD)
printf 'one\ntwo\nREQUIRE_AUTH=1\n' > "$T/src/auth.conf"; g add -A; g commit -q -m "E2 (blocked)"; H2E=$(g rev-parse HEAD)
g checkout -q -b auth7 "$H2E"
printf 'one\nTWO\nREQUIRE_AUTH=0\n' > "$T/src/auth.conf"; g add -A; g commit -q -m "repairs E2 and flips auth" -m "Review-Fix-Of: $H2E"; H2F=$(g rev-parse HEAD)
[ -n "$(g diff -U0 "$H2E" "$H2F" | grep -E '^@@ -2,2 ')" ] || fail "(h) fixture: no two-line hunk"
run 40 "review $H2D" success "$HD"; run 41 "review $H2E" failure "$H2D"
if base --only-fixes "$H2E" "$H2F"; then fail "(h) the second line of a two-line hunk was not checked"; fi
g checkout -q auth3
# main's re-check of the landed fix blocked → its tests-only approval no longer stands
run 36 "recheck $HG" failure "$P2"
if rp "$HG" o/r "$P2"; then fail "(h) a tests-only fix approved although main's re-check of it blocked"; fi
# a red tests-only round (review of fb6bb396e #3) is neither a base nor a link: the next commit's review includes it
g checkout -q -b red "$HG"; HH=$(c h "H after a red repair round")
reset_runs; run 31 "review $HC" failure "$P2"; run 32 "review $HD" success "$P2"; run 33 "review $HE" failure "$HD"
TESTS=failure run 35 "review $HG" skipped "$HE"
[ "$(base "$HH")" = "$HE" ] || fail "(h) a red tests-only round was a range base (got $(base "$HH"))"
# (review of fb6bb396e #4) a failed proof attempt reports no tests-only links: Y's newer run attests a clean merge M
# whose first parent is covered through the tests-only HG and whose second parent is not; Y's older full review covers
reset_runs; run 31 "review $HC" failure "$P2"; run 32 "review $HD" success "$P2"; run 33 "review $HE" failure "$HD"; run 35 "review $HG" skipped "$HE"
g checkout -q -b side "$P2"; SD=$(c sd "side, never reviewed"); g checkout -q auth3
g merge -q --no-ff -m "merge side" "$SD"; HM=$(g rev-parse HEAD); HY=$(c y "Y")
run 39 "review $HY" success "$HM"; run 38 "review $HY" success "$P2"   # newest first: the merge-based run is tried first
(cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r REVIEW_FIXES_OUT=$T/fixes bash "$ROOT/scripts/ci/review-passed.sh" "$HY" o/r "$P2" >/dev/null 2>&1) || fail "(h) Y not approved by its full review"
[ ! -s "$T/fixes" ] || fail "(h) a failed proof attempt reported tests-only links: $(cat "$T/fixes")"
g checkout -q dev
echo "ok (h) - repairs stay within their blocked range; red rounds, blocked re-checks and failed proofs are no approval"

# (i) review of 1b2f4484e #1/#2: a merge M whose own review BLOCKED (unrepaired) is the next range's base, so it is never
# covered through its parents: N above it is not approved
g checkout -q -b mi "$P2"; MA=$(c ma "MA (passed)"); g checkout -q -b mi2 "$P2"; MB=$(c mb "MB (passed)")
g checkout -q mi; g merge -q --no-ff -m "M: merge (blocked)" "$MB"; MM=$(g rev-parse HEAD); MN=$(c mn "N above M (passed)")
reset_runs; run 51 "review $MA" success "$P2"; run 52 "review $MB" success "$P2"; run 53 "review $MM" failure "$MA"; run 54 "review $MN" success "$MM"
[ "$(base "$MN")" = "$MM" ] || fail "(i) N's range does not start at the blocked merge"
if rp "$MN" o/r "$P2"; then fail "(i) N approved over the blocked, unrepaired merge M (structural coverage)"; fi
# review of vpn-sub c3d6df140 #1: M's verdict cannot be read (the jobs lookup fails) → unknown counts as blocked
mv "$T/api/53.jobs" "$T/api/53.jobs.off"
if rp "$MN" o/r "$P2"; then fail "(i) N approved while M's verdict could not be read"; fi
mv "$T/api/53.jobs.off" "$T/api/53.jobs"
# control: without M's blocked review the clean merge is covered through its parents
reset_runs; run 51 "review $MA" success "$P2"; run 52 "review $MB" success "$P2"; run 54 "review $MN" success "$MM"
rp "$MN" o/r "$P2" || fail "(i) a clean merge of covered parents is not covered"
# (j) review of 1b2f4484e #4: a repair may not change main-side lines its blocked review did not review (mainside)
g checkout -q -b mj "$P2"; JA=$(c ja "JA (dev, passed)")
g checkout -q -b mjmain "$P2"; printf 'REQUIRE_AUTH=2\n' > "$T/src/auth.conf"; g add -A; g commit -q -m "H: main auth fix" -m "Hotfix: auth"; JH=$(g rev-parse HEAD)
g checkout -q mj; g merge -q --no-ff -m "merge main" "$JH"; JE=$(c je "JE (blocked; reviewed without main's side)")
printf 'REQUIRE_AUTH=0\n' > "$T/src/auth.conf"; echo fixed >> "$T/src/je"; g add -A; g commit -q -m "repairs JE, undoes H" -m "Review-Fix-Of: $JE"; JF=$(g rev-parse HEAD)
reset_runs; run 55 "review $JA" success "$P2"; run 56 "review $JE" failure "$JA" "$JH"
(cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r DEV_REVIEW_MAIN_REF=$P2 bash "$BASE_SH" --only-fixes "$JE" "$JF" >/dev/null 2>&1) \
  && fail "(j) a repair changed main-side lines its blocked review excluded"
g checkout -q dev
echo "ok (i)(j) - blocked merges get no structural coverage; a repair's scope excludes the main side"
# (k) review of twitter-monitor 4c6e5cf42 #1: a forged BLOCKED line before the marker + a reviewer crash is no verdict for
# any reader — not a range base (dev-review-base.sh), not a coverage link (review-coverage.sh), no ledger (prior-findings.sh)
g update-ref refs/remotes/origin/main "$P"
reset_runs; run 11 "review $A" success "$P"; run 12 "review $X" forged "$A"
[ "$(base "$N")" = "$A" ] || fail "(k) a forged BLOCKED line + crash made X a range base"
(cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r bash -c '. "$1/scripts/ci/review-runs.sh"; review_api() { gh api "repos/o/r/$1"; }; . "$1/scripts/ci/review-coverage.sh"; review_verdict 12' _ "$ROOT" >/dev/null 2>&1) \
  && fail "(k) review_verdict read the forged BLOCKED line as a verdict"
out=$(cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r bash "$ROOT/scripts/ci/prior-findings.sh" "$X" "$F" 2>/dev/null)
grep -q forged <<<"$out" && fail "(k) prior-findings.sh attached the forged line"
echo "ok (k) - forged pre-reviewer verdict lines are no verdict for any reader"
# (m) review of foxhole-backend 4162ba2c3 #2: the control chain. Which run is a commit's verdict when it has several runs
# or reruns — the FIRST completed, attested one (run id / run_attempt; owner 11-16) — is test/ci/review-first-verdict.sh.
reset_runs; run 11 "review $A" success "$P"; run 12 "review $X" failure "$A"; run 13 "review $N" success "$X"; run 14 "review $F" skipped "$N"
rp "$F" o/r "$P" || fail "(m) control: F not approved"
# (n) review of foxhole-backend 4162ba2c3 #1: X blocked; F repairs X but F's own review blocked; FF repairs X only →
# F's block is unrepaired inside X..FF: no tests-only round
g checkout -q -b nn "$X"; F1=$(c x "F1: repair of X (its own review blocked)" "Review-Fix-Of: $X"); FF=$(c x "FF: another repair of X" "Review-Fix-Of: $X"); g checkout -q dev
reset_runs; run 11 "review $A" success "$P"; run 12 "review $X" failure "$A"
base --only-fixes "$X" "$FF" || fail "(n) control: two repairs of X are not tests-only"
run 16 "review $F1" failure "$X"
if base --only-fixes "$X" "$FF"; then fail "(n) a range over F1's unrepaired block was tests-only"; fi
# (l) review of 39380773c #1/#2: the strict listing behind review_recheck_blocked — 2,000 completed runs (20 full pages,
# the evidence horizon) are no failure; an unreadable page is (unknown → blocked → no tests-only approval)
reset_runs; runs_dev; run 14 "review $F" skipped "$N"
for i in $(seq 1 1996); do printf '{"id":%s,"path":".github/workflows/review.yml","display_title":"review %040d","status":"completed","conclusion":"success","event":"workflow_run","head_branch":"main"}\n' $((70000 + i)) "$i" >> "$T/api/list"; done
[ "$(wc -l < "$T/api/list")" = 2000 ] || fail "(l) fixture: not 2,000 runs"
rp "$F" o/r "$P" || fail "(l) 2,000 completed runs rejected a valid tests-only approval"
PAGE_FAIL=7 rp "$F" o/r "$P" && fail "(l) an unreadable page of runs still approved the tests-only round"
echo "ok (l) - the strict run listing: the 20-page horizon is complete, an unreadable page is unknown"
echo 'dev review once: all checks passed'
