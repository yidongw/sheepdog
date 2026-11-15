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
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
ROOT=$PWD
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q -b main "$T/src"
g() { git -C "$T/src" -c user.name=t -c user.email=t@t "$@"; }
c() { echo "$RANDOM $2" >> "$T/src/$1"; g add "$1"; g commit -q -m "$2" ${3:+-m "$3"}; g rev-parse HEAD; }
P=$(c f production)
g update-ref refs/remotes/origin/main "$P"
g checkout -q -b dev
A=$(c a "A")
X=$(c x "X (its review blocked)")
N=$(c n "N")
F=$(c x "F: repair of X" "Review-Fix-Of: $X")

# fake GitHub API: $T/api/list (the run listing), <id>.jobs (latest attempt), <id>.a<k>.jobs (earlier attempts),
# <job id>.log, <id>.zip (the run's attestation)
mkdir -p "$T/bin" "$T/api"
reset() { : > "$T/api/list"; rm -f "$T/api/"*.jobs "$T/api/"*.zip "$T/api/"*.log "$T/api/"*.nozip; }
# listing <id> <title> [<run_attempt>] [<status>] [<conclusion>]
listing() {
  printf '{"id":%s,"path":".github/workflows/review.yml","display_title":"%s","status":"%s","conclusion":%s,"event":"workflow_run","head_branch":"main","run_attempt":%s}\n' \
    "$1" "$2" "${4:-completed}" "$([ "${4:-completed}" = completed ] && echo "\"${5:-success}\"" || echo null)" "${3:-1}" >> "$T/api/list"
}
# attempt <id> <k> <latest k> <step: success|failure|skipped|crash|cancelled|running> [<tests conclusion>]
attempt() {
  local id=$1 k=$2 n=$3 st=$4 jid=$(( $1 * 10 + $2 )) js=completed jc sc f
  case "$st" in
    success|skipped) jc=success; sc=$st ;;
    failure) jc=failure; sc=failure ;;
    crash) jc=failure; sc=failure ;;
    cancelled) jc=cancelled; sc=cancelled ;;
    running) js=in_progress; jc=; sc= ;;
  esac
  f=$T/api/$id.jobs; [ "$k" = "$n" ] || f=$T/api/$id.a$k.jobs
  printf '{"jobs":[{"name":"tests","run_attempt":%s,"status":"completed","conclusion":"%s","steps":[]},{"name":"review","id":%s,"run_attempt":%s,"status":"%s","conclusion":%s,"completed_at":"2026-11-15T12:00:00Z","steps":[{"name":"Review (blocking)","conclusion":%s}]}]}\n' \
    "$k" "${5:-success}" "$jid" "$k" "$js" "$([ -n "$jc" ] && echo "\"$jc\"" || echo null)" "$([ -n "$sc" ] && echo "\"$sc\"" || echo null)" > "$f"
  { echo "2026-11-15T00:00:01.0Z review-gate: reviewing run $id attempt $k"
    [ "$st" = failure ] && echo "2026-11-15T00:00:02.0Z review-gate: BLOCKED #1 regression [should]: finding of run $id attempt $k"
    [ "$st" = crash ] && echo "2026-11-15T00:00:02.0Z review-gate: reviewer failed: crashed"; true; } > "$T/api/$jid.log"
}
# att <id> <head> <base> [<kind>]
att() {
  jq -nc --arg h "$2" --arg b "$3" --arg k "${4:-review}" --arg m "$P" '{head: $h, base: $b, kind: $k, main: $m}' > "$T/api/att.json"
  python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.write(sys.argv[2],"review-attestation.json"); z.close()' "$T/api/$1.zip" "$T/api/att.json"
}
# a one-attempt completed run with its attestation: run1 <id> <title> <step> <attested base> [<kind>]
run1() {
  local k=review; [ "$3" = skipped ] && k=tests-only-fix
  listing "$1" "$2" 1 completed "$([ "$3" = success ] || [ "$3" = skipped ] && echo success || echo failure)"
  attempt "$1" 1 1 "$3"; att "$1" "${2#* }" "$4" "${5:-$k}"
}
cat > "$T/bin/page" <<PAGE
#!/usr/bin/env bash
p=\$(sed -nE 's/.*[?&]page=([0-9]+).*/\1/p' <<<"\$1"); p=\${p:-1}
st=\$(sed -nE 's/.*[?&]status=([a-z]+).*/\1/p' <<<"\$1")
sed -n "\$(( (p - 1) * 100 + 1 )),\$(( p * 100 ))p" "$T/api/list" | jq -s --arg st "\$st" '{workflow_runs: [.[] | select(\$st == "" or (\$st == "completed" and .status == "completed") or .conclusion == \$st)]}'
PAGE
cat > "$T/bin/answer" <<ANS
#!/usr/bin/env bash
u=\${1#*repos/o/r/}
case "\$u" in
  *workflows/review.yml/runs*) "$T/bin/page" "\$u" ;;
  actions/runs/*/attempts/*/jobs) id=\${u#actions/runs/}; k=\${id#*/attempts/}; id=\${id%%/*}; cat "$T/api/\$id.a\${k%%/*}.jobs" 2>/dev/null || exit 22 ;;
  actions/runs/*/jobs) id=\${u#actions/runs/}; cat "$T/api/\${id%%/*}.jobs" 2>/dev/null || exit 22 ;;
  actions/jobs/*/logs) id=\${u%/logs}; cat "$T/api/\${id##*/}.log" 2>/dev/null || exit 22 ;;
  actions/runs/*/artifacts) id=\${u#actions/runs/}; id=\${id%%/*}; if [ -e "$T/api/\$id.zip" ]; then echo "{\"artifacts\":[{\"name\":\"review-attestation\",\"id\":\$id}]}"; else echo '{"artifacts":[]}'; fi ;;
  actions/artifacts/*/zip) id=\${u%/zip}; [ ! -e "$T/api/\${id##*/}.nozip" ] || exit 22; cat "$T/api/\${id##*/}.zip" ;;
  *) exit 22 ;;
esac
ANS
cat > "$T/bin/curl" <<CURL
#!/usr/bin/env bash
"$T/bin/answer" "\${@: -1}"
CURL
cat > "$T/bin/gh" <<GH
#!/usr/bin/env bash
[ "\$1" = api ] || exit 1
q=""; [ "\${3:-}" = -q ] && q=\$4
case "\$2" in */zip|*/logs) exec "$T/bin/answer" "\$2" ;; esac
j=\$("$T/bin/answer" "\$2") || exit 1
if [ -n "\$q" ]; then jq -r "\$q" <<<"\$j"; else printf '%s\n' "\$j"; fi
GH
chmod +x "$T/bin/"*
env_() { (cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r "$@"); }
# the shared reader itself: verdict <sha> <mode> → "<kind> <run> <attempt>" | "unknown <run> <attempt>" | "none"
verdict() {
  env_ bash -c '. "$1/scripts/ci/review-runs.sh"; review_api() { gh api "repos/o/r/$1"; }; . "$1/scripts/ci/review-coverage.sh"
    rc=0; review_first_verdict_line "$2" "$3" || rc=$?; [ "$rc" != 1 ] || echo none' _ "$ROOT" "$1" "$2" 2>/dev/null
}
rp() { env_ bash "$ROOT/scripts/ci/review-passed.sh" "$@" >/dev/null 2>&1; }
expect() { local got; got=$(verdict "$1" "$2"); [ "$got" = "$3" ] || fail "$4: the verdict of ${1:0:7} ($2) is '$got', expected '$3'"; }
# the dev chain: A passed (11), X blocked (12), N passed (13); F is the tests-only round over N (repairs X)
chain() { run1 11 "review $A" success "$P"; run1 12 "review $X" failure "$A"; run1 13 "review $N" success "$X"; }

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

# (5) attempts of one run: attempt 1 decides over attempt 2
reset; listing 30 "review $A" 2 completed failure; attempt 30 1 2 success; attempt 30 2 2 failure; att 30 "$A" "$P"
expect "$A" any "pass 30 1" "(5) pass then a blocked rerun"
reset; listing 30 "review $A" 2 completed success; attempt 30 1 2 failure; attempt 30 2 2 success; att 30 "$A" "$P"
expect "$A" any "blocked 30 1" "(5) blocked then a passing rerun"
reset; listing 30 "review $A" 2 completed success; attempt 30 1 2 cancelled; attempt 30 2 2 success; att 30 "$A" "$P"
expect "$A" any "pass 30 2" "(5) a cancelled attempt has no verdict"
echo "ok (5) - attempts in order: the first attempt with a verdict decides"

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
echo 'review first verdict: all checks passed'
