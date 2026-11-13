#!/usr/bin/env bash
# Dev reviews (owner 11-12: "review on dev once; if it fails, fix once; when CI passes, merge into main without a second review"; "every commit is reviewed once"), mirroring
# main's re-checks (test/ci/main-review-range.sh): the reviewed range starts at the last COMPLETED dev review that passed
# or whose block is repaired — not at merge-base(main, dev); a blocked commit without its repair is reviewed again with
# the next commits (never lands on an unrelated commit's review); clean main→dev merges right above the base are not
# diffed; a range of only fixes of earlier BLOCKED reviews (+ clean merges) is a tests-only-fix round (reviewer skipped,
# never a pass; review-passed.sh accepts it on its tests and its own re-check), and the merge-train lands it; the strict deploy checker follows a chain of completed rounds to prod.
# 11-12: every dev round reviewed all 38 commits again and found something new — dev stuck 7.5 h.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
cd "$(dirname "$0")/../.."
ROOT=$PWD
BASE_SH=$ROOT/scripts/ci/dev-review-base.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q -b main "$T/src"
g() { git -C "$T/src" -c user.name=t -c user.email=t@t "$@"; }
c() { echo "$RANDOM" >> "$T/src/$1"; g add "$1"; g commit -q -m "$2" ${3:+-m "$3"}; g rev-parse HEAD; }
P=$(c f production)
g checkout -q -b dev
D1=$(c a "dev one")
X=$(c a "dev two (its review blocked)")
g checkout -q main
H=$(c hot "hotfix on main" "Hotfix: h")
g update-ref refs/remotes/origin/main "$H"
g checkout -q dev
g merge -q --no-ff -m "merge main into dev" main; M=$(g rev-parse HEAD)
F=$(c a "fix of X" "Review-Fix-Of: $X")
g branch keep-f "$F"

# fake GitHub API (curl for dev-review-base.sh, gh for review-passed.sh): one file per run under $T/api
mkdir -p "$T/bin" "$T/api"
: > "$T/api/list"
run() { # run <id> <title> <blocking step conclusion: success|failure|crash|skipped|cancelled> [<attested base>] [<review-range base>]
  # failure = the reviewer's verdict "review-gate: BLOCKED #1" in the job log; crash = the step failed without one
  local st=$3; [ "$st" = crash ] && st=failure
  printf '{"id":%s,"path":".github/workflows/review.yml","display_title":"%s","status":"completed","event":"workflow_run","head_branch":"main"}\n' "$1" "$2" >> "$T/api/list"
  printf '{"jobs":[{"name":"tests","conclusion":"success","steps":[]},{"name":"review","id":%s,"conclusion":"%s","steps":[{"name":"Review (blocking)","conclusion":"%s"}]}]}\n' \
    "$(($1 + 1000))" "$([ "$st" = success ] || { [ "$st" = skipped ] && [ -n "${KIND:-}" ]; } && echo success || echo failure)" "$st" > "$T/api/$1.jobs"
  { [ -n "${5:-}" ] && echo "2026-11-13T00:00:00.0Z review-range: $5 ${2#* }"; echo "2026-11-13T00:00:01.0Z review-gate: reviewing"
    [ "$3" = failure ] && echo "2026-11-13T00:00:02.0Z review-gate: BLOCKED #1 regression [should]: x"
    [ "$3" = crash ] && echo "2026-11-13T00:00:02.0Z Error: reviewer exited 2"
    [ -n "${EXTRA:-}" ] && seq 1 "$EXTRA" | sed 's/^/2026-11-13T00:00:03.0Z evidence: line /'; true; } > "$T/api/$(($1 + 1000)).log"
  # review contract: a review is a range base only with a usable attestation; DEFAULT_ATT gives every run one (sections
  # 1-4 test range selection, not proof) — sections 5-6 pass it explicitly to test a missing one
  local att=${4:-${DEFAULT_ATT:-}}
  if [ -n "$att" ]; then
    printf '{"head":"%s","base":"%s"%s}\n' "${2#* }" "$att" "${KIND:+,\"kind\":\"$KIND\",\"main\":\"$H\"}" > "$T/api/review-attestation.json"
    python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.write(sys.argv[2],"review-attestation.json"); z.close()' "$T/api/$1.zip" "$T/api/review-attestation.json"
  fi
  true
}
filler() { local i; for i in $(seq 1 "$1"); do printf '{"id":%s,"path":".github/workflows/review.yml","display_title":"review %040d","status":"completed","event":"workflow_run","head_branch":"main"}\n' $((5000 + i)) "$i" >> "$T/api/list"; done; }
reset_runs() { : > "$T/api/list"; rm -f "$T/api/"*.jobs "$T/api/"*.zip "$T/api/"*.log; }
# pages of 100, like the API (newest first = file order)
cat > "$T/bin/page" <<PAGE
#!/usr/bin/env bash
p=\$(sed -nE 's/.*[?&]page=([0-9]+).*/\1/p' <<<"\$1"); p=\${p:-1}
sed -n "\$(( (p - 1) * 100 + 1 )),\$(( p * 100 ))p" "$T/api/list" | jq -s '{workflow_runs: .}'
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
base() { (cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r bash "$BASE_SH" "$@" 2>/dev/null); }

DEFAULT_ATT=$P
# 1. the base: the last completed dev review that passed, or blocked and is repaired in the range — not merge-base
run 21 "review $X" failure
test "$(base HEAD)" = "$X"                                   # X blocked, F repairs it → only what came after X
reset_runs; run 21 "review $X" skipped                       # setup / commit gates failed: the reviewer never ran
test "$(base HEAD)" = "$H"
reset_runs; run 21 "review $X" cancelled
test "$(base HEAD)" = "$H"                                   # none completed above main → merge-base (as before)
reset_runs; run 23 "review $P" success
test "$(base HEAD)" = "$H"                                   # a review of a commit on main is below the walk
N1=$(c a "new dev work"); N2=$(c a "more dev work"); g branch n2 "$N2"
reset_runs; run 22 "review $N1" cancelled; run 21 "review $X" failure
test "$(base HEAD)" = "$X"                                   # a cancelled review of the parent reviewed nothing
reset_runs; run 22 "review $N1" success; run 21 "review $X" failure
test "$(base HEAD)" = "$N1"                                  # a passed review: the base
# R blocked, an unrelated S after it, no repair → R is reviewed again with S (from where R's review started)
g checkout -q -b rs "$H"; R=$(c b "R (blocked)"); S=$(c b "S (unrelated)")
reset_runs; run 31 "review $R" failure
test "$(base HEAD)" = "$H"
g checkout -q -b rs2 "$D1"; R=$(c b "R (blocked)"); S=$(c b "S (unrelated)")
reset_runs; run 32 "review $D1" success; run 31 "review $R" failure "" "$D1"
test "$(base HEAD)" = "$D1"                                  # the base stays where R's review started
if base --only-fixes "$D1" "$S"; then echo "unrelated S after an unrepaired R skipped" >&2; exit 1; fi
RF=$(c rf "repair of R" "Review-Fix-Of: $R"); c b "S2" >/dev/null
test "$(base HEAD)" = "$R"                                   # repaired → past R
g revert --no-edit "$RF" >/dev/null; c b "S3" >/dev/null
test "$(base HEAD)" = "$D1"                                  # the repair was reverted → R reviewed again
g checkout -q dev
# a review whose step failed without the reviewer's verdict (crash / setup) reviewed nothing: not a base, not "blocked"
reset_runs; run 21 "review $X" crash
test "$(base HEAD)" = "$H"
if base --only-fixes "$X" "$F"; then echo "a fix of a crashed review skipped" >&2; exit 1; fi
# the run lookups read every page (the review of X is older than the newest 100 runs)
reset_runs; filler 150; run 21 "review $X" failure
test "$(base HEAD)" = "$X"
# a long log after the verdict (the range line read without an early-closed pipe: SIGPIPE under pipefail lost it)
reset_runs; EXTRA=3000 run 21 "review $X" failure "" "$D1"
test "$(base HEAD)" = "$X"
base --only-fixes "$X" "$F"
echo 'dev range base: last completed review that passed or is repaired; an unrepaired block is reviewed again'

# 2. the diff starts past clean main→dev merges right above the base (their main side was reviewed on main)
#    — review contract: only when that main side has its own completed main review (proof, review-coverage.sh)
test "$(base --diff "$X" "$N2")" = "$X"                      # H's re-check never ran: not moved past
run 61 "recheck $H" success
test "$(base --diff "$X" "$N2")" = "$M"
test "$(g diff --name-only "$M" "$N2")" = a
test "$(base --diff "$F" "$N2")" = "$F"                      # no merge right above F
g checkout -q -b evil "$X"; g merge -q --no-ff --no-commit main >/dev/null 2>&1; echo evil > "$T/src/evil"; g add evil; g commit -q -m "merge main (with code of its own)"
EF=$(c a "fix of X again" "Review-Fix-Of: $X")
test "$(base --diff "$X" "$EF")" = "$X"                      # an evil merge is not moved past
echo 'diff base: past clean main→dev merges right above the base; never past a merge with code of its own'

# 3. only fixes of an earlier BLOCKED review (+ clean merges, main's commits) → skipped; anything else reviewed
reset_runs; run 21 "review $X" failure
base --only-fixes "$X" "$F"
if base --only-fixes "$X" "$N2"; then echo "new dev work skipped" >&2; exit 1; fi
if base --only-fixes "$D1" "$F"; then echo "a range with unreviewed X skipped" >&2; exit 1; fi
if base --only-fixes "$F" "$F"; then echo "empty range skipped" >&2; exit 1; fi
if base --only-fixes "$X" "$EF"; then echo "a merge with code of its own skipped" >&2; exit 1; fi
reset_runs; run 21 "review $X" success
if base --only-fixes "$X" "$F"; then echo "fix of a review that passed skipped" >&2; exit 1; fi
reset_runs; run 21 "review $X" failure; run 22 "review $F" failure
if base --only-fixes "$X" "$N2"; then echo "x" >&2; exit 1; fi
g checkout -q -b fixfix "$F"; FF=$(c a "fix of X, more" "Review-Fix-Of: $X")
if base --only-fixes "$X" "$FF"; then echo "a fix whose own review blocked (unrepaired) skipped" >&2; exit 1; fi
FF2=$(c a "fix of F" "Review-Fix-Of: $F")
base --only-fixes "$X" "$FF2"                                # once F is repaired, the fixes are fixes again
g checkout -q -b fake "$H"; FK=$(c a "first contribution" "Review-Fix-Of: $P")
reset_runs
if base --only-fixes "$H" "$FK"; then echo "Review-Fix-Of an old main commit with no blocked review skipped" >&2; exit 1; fi
run 41 "recheck $P" failure
base --only-fixes "$H" "$FK"                                 # a fix of a blocked main re-check counts
g checkout -q dev
# the f68613dd4 shape (11-12): Q0 passed; R9 and R3 blocked (their reviews ran from Q0); main merged in (Mx, blocked
# too, from Q0, unrepaired); Fh repairs R3 only. The base may be no newer than Mx's / R9's own start (Q0), and no skip:
# blocked, unrepaired commits (R9, the merge Mx) lie in the range.
g checkout -q -b shape "$H"; Q0=$(c q "Q0"); R9=$(c q "R9"); R3=$(c q "R3")
g checkout -q -b main2 "$H"; H2=$(c hot2 "hotfix two" "Hotfix: h2"); g checkout -q shape
g merge -q --no-ff -m "merge main into dev" main2; Mx=$(g rev-parse HEAD)
Fh=$(c q "repair of R3" "Review-Fix-Of: $R3")
g update-ref refs/remotes/origin/main "$H2"
reset_runs; run 71 "review $Q0" success; run 72 "review $R9" failure "" "$Q0"; run 73 "review $R3" failure "" "$Q0"; run 74 "review $Mx" failure "" "$Q0"
test "$(base HEAD)" = "$Q0"
if base --only-fixes "$R3" "$Fh"; then echo "a range with a blocked, unrepaired merge skipped" >&2; exit 1; fi
if base --only-fixes "$Q0" "$Fh"; then echo "a range with blocked, unrepaired R9 skipped" >&2; exit 1; fi
FR=$(c q "repair of R9 and Mx" "Review-Fix-Of: $R9
Review-Fix-Of: $Mx")
test "$(base HEAD)" = "$Mx"                                  # everything repaired → past the newest repaired round
base --only-fixes "$Mx" "$FR"
g update-ref refs/remotes/origin/main "$H"; g checkout -q dev
echo 'only-fixes dev range: skipped only for fixes of blocked reviews; anything else reviewed'

# 4. review.yml's dev steps on a fix-only head (review contract (b)): kind tests-only-fix — the blocking reviewer step is
#    SKIPPED (never a pass), the attestation says so; new work above the last review → reviewed from there, main's merge
#    diffed out (its main side H has its own completed re-check)
g checkout -q -B dev "$F"
reset_runs; run 21 "review $X" failure "$P"; run 61 "recheck $H" success "$P"
git clone -q "$T/src" "$T/candidate"; git -C "$T/candidate" checkout -q --detach "$F"
mkdir -p "$T/.sheepdog" "$T/.trusted"; ln -s "$ROOT/scripts" "$T/.sheepdog/scripts"
python3 - "$T" <<'PY'
import sys, yaml
w = yaml.safe_load(open(".github/workflows/review.yml"))
steps = w["jobs"]["review"]["steps"]
step = lambda n: next(s for s in steps if (s.get("name") or "").startswith(n))
env = "HEAD_BRANCH=dev MAIN_BRANCH=main DEV_BRANCH=dev REVIEW_DEFAULT_BRANCH=main\n"
open(sys.argv[1] + "/range.sh", "w").write(env + step("Reviewed range")["run"])
open(sys.argv[1] + "/attest.sh", "w").write('KIND=$RANGE_KIND\n' + step("Attestation")["run"])
if step("Review (blocking").get("if") != "steps.range.outputs.kind == 'review'": sys.exit("the blocking reviewer runs on a tests-only fix round")
up = next(s for s in steps if (s.get("uses") or "").startswith("actions/upload-artifact"))
if "!cancelled()" not in str(up.get("if")): sys.exit("attestation not uploaded for a blocked review")
if "steps.attest.outcome == 'success'" not in str(up.get("if")): sys.exit("attestation uploaded without its step succeeding")
PY
export GITHUB_ENV=$T/env GITHUB_OUTPUT=$T/out; : > "$GITHUB_ENV"; : > "$GITHUB_OUTPUT"
out=$(cd "$T/candidate" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r bash -e "$T/range.sh" 2>&1)
grep -q "^dev review: covers from ${X:0:12}" <<<"$out" || { echo "range: $out" >&2; exit 1; }
grep -qx "review-range: $M $F" <<<"$out"
grep -qx 'kind=tests-only-fix' "$GITHUB_OUTPUT"
(cd "$T/candidate" && set -a && . "$GITHUB_ENV" && set +a && RANGE_KIND=tests-only-fix bash -e "$T/attest.sh" >/dev/null)
test "$(jq -r .base "$T/attest/review-attestation.json")" = "$M"   # the diffed base (past the clean main merge)
test "$(jq -r .kind "$T/attest/review-attestation.json")" = tests-only-fix
git -C "$T/candidate" checkout -q --detach origin/n2; : > "$GITHUB_ENV"; : > "$GITHUB_OUTPUT"
(cd "$T/candidate" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r bash -e "$T/range.sh" >/dev/null 2>&1)
grep -qx 'kind=review' "$GITHUB_OUTPUT"; grep -qx "REVIEW_BASE=$M" "$GITHUB_ENV"
echo 'review.yml: dev range from the last completed dev review; fix-only head is a tests-only-fix round (reviewer skipped)'

DEFAULT_ATT=   # from here on an attestation is only where a run passes one (proof is under test)
# 5. the merge-train lands a tests-only fix head (review contract (b)): review-passed.sh accepts the run (tests passed,
#    the blocking step SKIPPED, attestation kind tests-only-fix, its own --only-fixes re-check against the attested main)
#    and merge-branch.sh — the train's landing call — fast-forwards main to it, X included: F carries Review-Fix-Of:, so
#    main re-checks it. A tests-only approval without such a trailer is not landed.
git clone -q --bare "$T/src" "$T/origin.git"
git -C "$T/origin.git" update-ref refs/heads/main "$H"; git -C "$T/origin.git" update-ref refs/heads/dev "$F"
git clone -q "$T/origin.git" "$T/work"
KIND=tests-only-fix run 51 "review $F" skipped "$X"
git -C "$T/work" merge-base --is-ancestor "$H" "$F"
(cd "$T/work" && PATH=$T/bin:$PATH REPO=o/r bash "$ROOT/scripts/ci/merge-branch.sh" dev "$F" >/dev/null 2>&1)
test "$(git -C "$T/origin.git" rev-parse refs/heads/main)" = "$F"
git -C "$T/origin.git" merge-base --is-ancestor "$X" refs/heads/main
echo 'merge-train lands a tests-only fix head (the blocked-and-fixed commits with it)'

# 6. the strict deploy checker (review-passed.sh <sha> <repo> <prod>): F's range starts at X, not at prod H; X's own
#    completed (blocked, then repaired) round attests H..X → the chain reaches prod and F is deployable. A link that
#    never reached a verdict, or has no attestation, breaks the chain (fail closed).
chk() { (cd "$T/src" && PATH=$T/bin:$PATH bash "$ROOT/scripts/ci/review-passed.sh" "$F" o/r "$H" >/dev/null 2>&1); }
chk
reset_runs; run 51 "review $F" success "$X"; run 21 "review $X" skipped "$P"
if chk; then echo "a round without a verdict covered prod" >&2; exit 1; fi
reset_runs; run 51 "review $F" success "$X"; run 21 "review $X" failure
if chk; then echo "a round without an attestation covered prod" >&2; exit 1; fi
reset_runs; run 51 "review $F" success "$X"
if chk; then echo "an unreviewed base covered prod" >&2; exit 1; fi
# a chain link that blocked only counts with the reviewer's BLOCKED verdict in its log (a crash reviewed nothing)
reset_runs; run 51 "review $F" success "$X"; run 21 "review $X" crash "$P"
if chk; then echo "a crashed round covered prod" >&2; exit 1; fi
# the chain lookup reads every page of runs, not only the newest 100
reset_runs; run 51 "review $F" success "$X"; filler 120; run 21 "review $X" failure "$P"
chk
# across a clean main→dev merge BOTH parents must be covered: F attests M (= X + main's H); prod P runs neither
chkp() { (cd "$T/src" && PATH=$T/bin:$PATH bash "$ROOT/scripts/ci/review-passed.sh" "$F" o/r "$P" >/dev/null 2>&1); }
reset_runs; run 51 "review $F" success "$M"; run 21 "review $X" failure "$D1"; run 24 "review $D1" success "$P"
if chkp; then echo "main's unreviewed hotfix H rode in through a merge" >&2; exit 1; fi
run 61 "recheck $H" success "$P"
chkp                                                        # H's own completed re-check covers it
# a long log after a blocked link's verdict still counts (grep -q on a pipe made gh/sed die of SIGPIPE: 11-12 re-check #2)
reset_runs; run 51 "review $F" success "$X"; EXTRA=3000 run 21 "review $X" failure "$P"
chk
# P → H → F on main: H's re-check BLOCKED (over P..H), the unrelated F passed over H..F, H never repaired → F does not
# cover prod P (11-12 re-check of d77e02b0f #1); P → H → fix(H) → F → covered.
g checkout -q -b mainline "$P"; HB=$(c m "hotfix H (its re-check blocked)" "Hotfix: hb"); FU=$(c m2 "unrelated F" "Hotfix: f")
chkm() { (cd "$T/src" && PATH=$T/bin:$PATH bash "$ROOT/scripts/ci/review-passed.sh" "$1" o/r "$P" >/dev/null 2>&1); }
reset_runs; run 81 "recheck $FU" success "$HB"; run 82 "recheck $HB" failure "$P"
if chkm "$FU"; then echo "an unrepaired blocked hotfix covered by an unrelated later review" >&2; exit 1; fi
g checkout -q -b mainline2 "$HB"; FX=$(c m "repair of H" "Review-Fix-Of: $HB
Hotfix: repair"); FU2=$(c m2 "unrelated F" "Hotfix: f")
reset_runs; run 83 "recheck $FU2" success "$HB"; run 82 "recheck $HB" failure "$P"
chkm "$FU2"
g revert --no-edit "$FX" >/dev/null; FU3=$(c m2 "F after the repair was reverted" "Hotfix: f3")
reset_runs; run 84 "recheck $FU3" success "$HB"; run 82 "recheck $HB" failure "$P"
if chkm "$FU3"; then echo "a reverted repair still covered the blocked hotfix" >&2; exit 1; fi
g checkout -q dev
echo 'strict checker: a chain of completed rounds back to prod is coverage; a broken chain is not'
echo 'dev review range checks passed'
