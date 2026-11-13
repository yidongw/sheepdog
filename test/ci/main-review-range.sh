#!/usr/bin/env bash
# Main re-checks (owner 11-12: "one dev review round, one hotfix review round"; one main reviewer at a time; the review contract,
# CLAUDE.md "Review contract", 11-13): the reviewed range starts at the last COMPLETED main review that still proves its
# range (trusted run, usable attestation; a blocked one only once repaired) — a reviewer cancelled while waiting, a crash,
# a branch's own run reviewed nothing; no completed review → the deployed sha (tag `deployed`), else the parent; no
# expansion to the hotfixes a repair replaces; nothing is moved past (a Train-Merge head is reviewed with everything since
# the last review); repairs of main findings are reviewed too (no skip on main); review.yml keeps tests per sha and
# serialises only the main reviewer.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
# Any command that is not found — a dispatcher helper the test did not extract — fails the whole test at once, even
# inside an if / || condition (review of 02828988f #7: "culprits_repaired: command not found" printed, test exited 0).
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
ROOT=$PWD
BASE_SH=$ROOT/scripts/ci/hotfix-review-base.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q -b main "$T/src"
g() { git -C "$T/src" -c user.name=t -c user.email=t@t "$@"; }
c() { echo "$RANDOM" >> "$T/src/f"; g add f; g commit -q -m "$1" ${2:+-m "$2"}; g rev-parse HEAD; }
P=$(c production)
H1=$(c "hotfix one" "Hotfix: one")
H2=$(c "hotfix two" "Hotfix: two")
H3=$(c "hotfix three" "Hotfix: three")

# fake GitHub API (curl on PATH), one file per run under $T/api; runs newest first in $T/api/list
mkdir -p "$T/bin" "$T/api"; : > "$T/api/list"
run() { # run <id> <sha> <blocking step: success|failure|crash|cancelled> [<attested base>] [<event, default workflow_run>]
  local st=$3 jc
  [ "$st" = crash ] && st=failure
  case "$st" in success) jc=success ;; cancelled) jc=cancelled ;; *) jc=failure ;; esac
  { printf '{"id":%s,"path":".github/workflows/review.yml","display_title":"recheck %s","status":"completed","event":"%s","head_branch":"main"}\n' "$1" "$2" "${5:-workflow_run}"; cat "$T/api/list"; } > "$T/api/l2"; mv "$T/api/l2" "$T/api/list"
  if [ "$st" = cancelled ]; then steps='[]'; else steps="[{\"name\":\"Review (blocking; main's reviewer, the branch's diff)\",\"conclusion\":\"$st\"}]"; fi
  printf '{"jobs":[{"name":"tests","conclusion":"success"},{"name":"review","id":%s,"conclusion":"%s","steps":%s}]}\n' "$(($1 + 1000))" "$jc" "$steps" > "$T/api/$1.jobs"
  { echo "2026-11-13T00:00:00.0Z review-range: ${4:-$P} $2"; [ "$3" = failure ] && echo "2026-11-13T00:00:01.0Z review-gate: BLOCKED #1 regression [should]: x"; true; } > "$T/api/$(($1 + 1000)).log"
  if [ -n "${4:-}" ]; then
    printf '{"head":"%s","base":"%s","kind":"review"}\n' "$2" "$4" > "$T/api/att.json"
    python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.write(sys.argv[2],"review-attestation.json"); z.close()' "$T/api/$1.zip" "$T/api/att.json"
  fi
}
reset_runs() { : > "$T/api/list"; rm -f "$T/api/"*.jobs "$T/api/"*.zip "$T/api/"*.log; }
cat > "$T/bin/curl" <<CURL
#!/usr/bin/env bash
u=\${@: -1}
case "\$u" in
  *workflows/review.yml/runs*page=1*) jq -s '{workflow_runs: .}' "$T/api/list" ;;
  *workflows/review.yml/runs*) echo '{"workflow_runs":[]}' ;;
  */actions/runs/*/jobs) id=\${u##*runs/}; id=\${id%%/*}; cat "$T/api/\$id.jobs" 2>/dev/null || exit 22 ;;
  */actions/jobs/*/logs) id=\${u%/logs}; cat "$T/api/\${id##*/}.log" 2>/dev/null || exit 22 ;;
  */actions/runs/*/artifacts) id=\${u##*runs/}; id=\${id%%/*}; if [ -e "$T/api/\$id.zip" ]; then echo "{\"artifacts\":[{\"name\":\"review-attestation\",\"id\":\$id}]}"; else echo '{"artifacts":[]}'; fi ;;
  */actions/artifacts/*/zip) id=\${u%/zip}; cat "$T/api/\${id##*/}.zip" ;;
  *) exit 22 ;;
esac
CURL
chmod +x "$T/bin/curl"
base() { (cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r bash "$BASE_SH" "$@" 2>/dev/null); }

# 1. base = the last completed main review with usable proof, not the parent whose reviewer was cancelled
run 11 "$H1" success "$P"; run 12 "$H2" cancelled
test "$(base HEAD)" = "$H1"
reset_runs; run 11 "$H1" success "$P"; run 12 "$H2" success "$H1"
test "$(base HEAD)" = "$H2"
reset_runs; run 11 "$H1" cancelled; run 12 "$H2" cancelled
test "$(base HEAD)" = "$H2"                                  # none completed → HEAD^1 (no deployed tag)
g tag deployed "$P"
test "$(base HEAD)" = "$P"                                   # … → the deployed sha when there is one (contract (f))
g tag -d deployed >/dev/null
reset_runs; run 11 "$H1" crash "$P"
test "$(base HEAD)" = "$H2"                                  # a failed step without the reviewer's verdict reviewed nothing
reset_runs; run 11 "$H1" success
test "$(base HEAD)" = "$H2"                                  # no attestation: no usable proof, not a base
reset_runs; run 11 "$H1" success "$P" push
test "$(base HEAD)" = "$H2"                                  # a branch's own run with the same title is not evidence
reset_runs; run 11 "$H1" failure "$P"
test "$(base HEAD)" = "$H2"                                  # blocked and not repaired: not a base
echo 'range base: last completed main review with usable proof; none → deployed sha, else HEAD^1'

# 2. no expansion: a repair of H3 is reviewed from H3 (its blocked, now repaired review), not together with H3's code again
F=$(c "repair of three" "Review-Fix-Of: $H3
Hotfix: repair")
reset_runs; run 13 "$H3" failure "$H2"
test "$(base HEAD)" = "$H3"
reset_runs
test "$(base HEAD)" = "$H3"                                  # no runs → the parent
F2=$(c "repair of the repair" "Review-Fix-Of: $F
Hotfix: repair again")
test "$(base HEAD)" = "$F"
echo 'no expansion to repaired hotfixes'

# 3. owner 11-13 "main must be right": a range of only repairs of earlier main re-checks is reviewed like any other —
#    hotfix-review-base.sh has no skip mode (it is a range base, nothing else)
if (cd "$T/src" && bash "$BASE_SH" --only-fixes "$H3" "$F2" >/dev/null 2>&1); then echo "hotfix-review-base.sh still answers --only-fixes" >&2; exit 1; fi
echo 'main repairs: no skip mode'

# 4. review contract (a): a Train-Merge head is NOT moved past — its merge resolution and the dev fixes it brings are
#    reviewed on main, with everything since the last completed main review
g checkout -q -b dev2 "$F2"; c "dev work" >/dev/null; g checkout -q -B main "$F2"
g merge -q --no-ff -m "train: reviewed dev onto main" -m "Train-Merge: x" dev2; M=$(g rev-parse HEAD)
reset_runs; run 14 "$F2" success "$H3"
test "$(base HEAD)" = "$F2"                                  # the merge head itself: from the last review
H4=$(c "hotfix four" "Hotfix: four")
test "$(base HEAD)" = "$F2"                                  # above the merge: still from the last review, M included
# a Review-Fix-Of: naming a non-ancestor is refused
c "bogus" "Review-Fix-Of: $(printf 'a%.0s' $(seq 40))
Hotfix: bogus" >/dev/null
if base HEAD >/dev/null; then echo "non-ancestor Review-Fix-Of accepted" >&2; exit 1; fi
echo 'train merges reviewed on main; non-ancestor trailers refused'

# 5. review.yml: tests per sha, ONE main reviewer group, no main skip, Train-Merge / Review-Fix-Of heads re-checked, the
#    review-range line for the dispatcher
python3 - <<'PY'
import sys, yaml
w = yaml.safe_load(open(".github/workflows/review.yml")); caller = yaml.safe_load(open("examples/.github/workflows/review.yml"))
j = w["jobs"]; r = j["review"]; bad = []
def ok(c, m):
    if not c: bad.append("review.yml: " + m)
ok("head_sha" in caller["concurrency"]["group"], "run-level group (the caller template) still per sha on main (tests for every head)")
ok("concurrency" not in j["tests"], "tests job not serialised")
rc = r.get("concurrency") or {}
ok("review-main-reviewer" in rc.get("group", "") and rc.get("cancel-in-progress") is False, "main reviewer: one group, cancel-in-progress false")
for t in ["Hotfix: ", "Train-Merge: ", "Review-Fix-Of: "]:
    ok(f"contains(github.event.workflow_run.head_commit.message, '{t}')" in r["if"], f"main heads with {t}are re-checked")
rng = next(s for s in r["steps"] if s.get("name") == "Reviewed range")["run"]
allrun = "\n".join(s.get("run", "") for s in r["steps"])
ok("hotfix-review-base.sh --only-fixes" not in allrun, "main only-fixes skip removed")
dev = rng[rng.index('= "$DEV_BRANCH" ]'):rng.index("else\n")]
ok('dev-review-base.sh" --only-fixes "$cover" HEAD; then kind=tests-only-fix' in dev, "tests-only-fix kind on dev")
ok(rng.count("kind=tests-only-fix") == 1, "tests-only-fix only on dev")
ok(next(s for s in r["steps"] if (s.get("name") or "").startswith("Review (blocking")).get("if") == "steps.range.outputs.kind == 'review'", "the reviewer skipped only for a tests-only fix round")
ok("review-range: $base" in rng, "review-range line")
ok("needs.review.result != 'cancelled'" in j["status"]["if"], "no status for a superseded reviewer")
for b in bad: print(b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo 'review.yml: tests per sha, one main reviewer, no main skip'
echo 'main review range checks passed'
