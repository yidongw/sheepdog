#!/usr/bin/env bash
# The dispatcher's GitHub API budget (11-13: eight dispatchers on one token spent ~6000 calls/h against GitHub's 5000/h;
# tralyx alone ~15 `gh run list` + the same completed runs' jobs and logs every minute). The WHOLE review-dispatch.sh runs
# on a fake repository (main: a hotfix whose re-check passed, one whose re-check blocked; dev: a reviewed head merged,
# a newer head under review; a devfix branch) against a fake `gh` that answers from fixture files and counts every
# invocation. T3 and the wake relay are stubs (nothing real is reached).
#   · run 1 (cold) and run 2 (a minute later, same state) stay within their call budgets;
#   · run 2 fetches no completed run's jobs / log a second time and lists each filter set once;
#   · the answers are the same as without the cache: the blocked re-check's findings reach the same notices;
#   · a re-run (listed again as queued, a new updatedAt) is read again, never answered from the stored attempt;
#   · the listing asks only for fields the host's gh (2.45) knows (11-13: `attempt` made every listing fail).
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FX=$T/fx; mkdir -p "$FX" "$T/bin"; export FX
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FX/calls"
exec python3 "$FX/../bin/fakegh.py" "$@"
SH
cat > "$T/bin/fakegh.py" <<'PY'
import json, os, re, subprocess, sys
FX = os.environ["FX"]
a = sys.argv[1:]
def load(f, d=None):
    try: return json.load(open(f"{FX}/{f}"))
    except (FileNotFoundError, json.JSONDecodeError):
        if d is None: sys.exit(1)
        return d
def opt(names):
    for i, x in enumerate(a):
        if x in names and i + 1 < len(a): return a[i + 1]
    return None
def emit(o, q):
    if q is None: print(json.dumps(o)); return
    r = subprocess.run(["jq", "-r", q], input=json.dumps(o), capture_output=True, text=True)
    sys.stdout.write(r.stdout); sys.exit(r.returncode)
if a[:2] == ["run", "list"]:
    runs = load("runs.json")
    wf, ev, br = opt(["-w"]), opt(["-e"]), opt(["-b"])
    if wf: runs = [r for r in runs if r["path"].endswith("/" + wf)]
    if ev: runs = [r for r in runs if r["event"] == ev]
    if br: runs = [r for r in runs if r["headBranch"] == br]
    runs = runs[: int(opt(["-L"]) or 20)]
    fields = (opt(["--json"]) or "").split(",")
    known = "conclusion createdAt databaseId displayTitle event headBranch headSha name number startedAt status updatedAt url workflowDatabaseId workflowName".split()
    bad = [f for f in fields if f and f not in known]   # gh 2.45 (the host's): e.g. no "attempt"
    if bad: sys.stderr.write(f"Unknown JSON field: {bad[0]!r}\n"); sys.exit(1)
    emit([{k: r.get(k) for k in fields if k} for r in runs], opt(["-q", "--jq"]))
    sys.exit(0)
if a[:2] in (["run", "cancel"], ["run", "rerun"]): sys.exit(0)
if a[0] == "api":
    path = next(x for x in a[1:] if not x.startswith("-") and x != opt(["-q", "--jq"]))
    path = re.sub(r"^repos/[^/]+/[^/]+/", "", path)
    q = opt(["-q", "--jq"])
    m = re.fullmatch(r"actions/runs/(\d+)", path)
    if m:
        r = next((r for r in load("runs.json") if r["databaseId"] == int(m.group(1))), None)
        if r is None: sys.exit(1)
        emit({"id": r["databaseId"], "status": r["status"], "conclusion": r["conclusion"], "updated_at": r.get("updatedAt")}, q); sys.exit(0)
    m = re.fullmatch(r"actions/runs/(\d+)/(jobs|artifacts)", path)
    if m: emit(load(f"{m.group(2)}-{m.group(1)}.json", {"jobs": [], "artifacts": []}), q); sys.exit(0)
    m = re.fullmatch(r"actions/artifacts/(\d+)/zip", path)
    if m:
        import io, zipfile
        f = f"{FX}/attest-{m.group(1)}.json"
        if not os.path.exists(f): sys.exit(1)
        b = io.BytesIO(); z = zipfile.ZipFile(b, "w"); z.write(f, "review-attestation.json"); z.close()
        sys.stdout.buffer.write(b.getvalue()); sys.exit(0)
    m = re.fullmatch(r"actions/runs/(\d+)/logs", path)
    if m: sys.stdout.buffer.write(open(f"{FX}/runlogs.bin", "rb").read()); sys.exit(0)
    m = re.fullmatch(r"actions/jobs/(\d+)/logs", path)
    if m:
        f = f"{FX}/log-{m.group(1)}.txt"
        if not os.path.exists(f): sys.exit(1)
        sys.stdout.write(open(f).read()); sys.exit(0)
    m = re.match(r"actions/workflows/([^/?]+)/runs\??(.*)", path)
    if m:
        qs = dict(kv.split("=", 1) for kv in m.group(2).split("&") if "=" in kv)
        rs = [r for r in load("runs.json") if r["path"].endswith("/" + m.group(1))] if qs.get("page", "1") == "1" else []
        emit({"workflow_runs": [{"id": r["databaseId"], "display_title": r["displayTitle"], "event": r["event"],
              "head_branch": r["headBranch"], "path": r["path"], "status": r["status"], "conclusion": r["conclusion"]} for r in rs]}, q)
        sys.exit(0)
sys.exit(1)
PY
# T3 / wake relay stubs: every launch and message is recorded, nothing real is reached
cat > "$T/bin/t3mcp" <<'SH'
#!/usr/bin/env bash
echo "$1 $2" >> "$FX/t3"
case "$1" in t3_thread_launch) echo '{"threadId":"mcp:aaaaaaaa-0000-0000-0000-000000000001"}' ;; *) echo '{"status":"running"}' ;; esac
SH
cat > "$T/bin/t3" <<'SH'
#!/usr/bin/env bash
echo "t3 $*" >> "$FX/t3"; echo '{"status":"running"}'
SH
chmod +x "$T/bin/gh" "$T/bin/t3mcp" "$T/bin/t3"

# the repository: main A ← H1 (re-check passed) ← H2 (re-check blocked); dev = main + D1 (reviewed, passed) + D2 (in review);
# devfix/<D1> left over
git init -q --bare -b main "$T/remote.git"; git init -q -b main "$T/w"; cd "$T/w"; git remote add origin "$T/remote.git"
g() { git -c user.name=t -c user.email=t@t "$@"; }
TH=mcp:11111111-1111-1111-1111-111111111111
c() { echo "$1 $RANDOM" >> "f-$1"; g add -A; g commit -q -m "$1" -m "${2:-}
Loop: adhoc/test
Thread: $TH
Verify:
- [x] t"; git rev-parse HEAD; }
mkdir -p .github; echo "sheepdog: {}" > .github/sheepdog.yml
A=$(c a); g tag deployed; H1=$(c h1 "Hotfix: one"); H2=$(c h2 "Hotfix: two")
g push -q origin main --tags
g checkout -q -b dev; D1=$(c d1); D2=$(c d2); g push -q origin dev
g checkout -q -b fx "$D1"; FXC=$(c fx "Review-Fix-Of: $D1"); g push -q origin "fx:refs/heads/devfix/$D1"
git clone -q "$T/remote.git" "$T/src"

RUNS=(); id=100
run() { # run <title> <path> <event> <branch> <head sha> <status> <conclusion> → the run id; jobs / log fixtures
  id=$((id + 1))
  local wn=Review; [ "$2" = .github/workflows/ci.yml ] && wn=CI
  RUNS+=("$(jq -nc --argjson id "$id" --arg t "$1" --arg p "$2" --arg wn "$wn" --arg ev "$3" --arg br "$4" --arg hs "$5" --arg st "$6" --arg c "$7" \
    '{databaseId: $id, displayTitle: $t, path: $p, workflowName: $wn, event: $ev, headBranch: $br, headSha: $hs, status: $st,
      conclusion: (if $c == "null" then null else $c end), createdAt: "2026-11-13T00:00:00Z", updatedAt: "2026-11-13T00:10:00Z", number: $id, name: "x"}')")
  local rc=$7; [ "$6" = completed ] || rc=null
  [ "$rc" = null ] && js=in_progress || js=completed
  local q='"'; [ "$rc" = null ] && q=""
  echo "{\"jobs\":[{\"id\":${id}1,\"name\":\"sheepdog / tests\",\"status\":\"$js\",\"conclusion\":${q}${rc/failure/success}${q}},{\"id\":${id}2,\"name\":\"sheepdog / review\",\"status\":\"$js\",\"conclusion\":${q}${rc}${q},\"steps\":[{\"name\":\"Review (blocking; x)\",\"conclusion\":${q}${rc}${q}}]}]}" > "$FX/jobs-$id.json"
  echo "{\"artifacts\":[{\"name\":\"review-attestation\",\"id\":$id,\"expired\":false}]}" > "$FX/artifacts-$id.json"
}
attest() { jq -nc --arg h "$2" --arg b "$3" '{head: $h, base: $b, kind: "review"}' > "$FX/attest-$1.json"; }
R=.github/workflows/review.yml C=.github/workflows/ci.yml
run "recheck $H1" $R workflow_run main "$H1" completed success; RH1=$id; attest $id "$H1" "$A"
printf 'review-range: %s %s\nreview-gate: PASS\n' "$A" "$H1" > "$FX/log-${RH1}2.txt"
run "recheck $H2" $R workflow_run main "$H2" completed failure; RH2=$id; attest $id "$H2" "$H1"
printf 'review-range: %s %s\nreview-gate: ROUTE author — x\nreview-gate: FINDING #1 route=author commit=%s — x\nreview-gate: BLOCKED #1 regression [should]: two drops rows\nevidence: f-h2:1 x\n' "$H1" "$H2" "$H2" > "$FX/log-${RH2}2.txt"
run "review $D1" $R workflow_run main "$D1" completed success; attest $id "$D1" "$H2"
printf 'review-range: %s %s\nreview-gate: PASS\n' "$H2" "$D1" > "$FX/log-${id}2.txt"
run "review $D2" $R workflow_run main "$D2" in_progress null
run "CI" $C push dev "$D2" in_progress null
run "CI" $C push main "$H2" completed success
run "CI" $C push "devfix/$D1" "$FXC" completed success
(IFS=,; echo "[${RUNS[*]}]") | jq 'reverse' > "$FX/runs.json"   # newest first, as GitHub lists
for f in "$FX"/log-*.txt; do sed -i 's/^/2026-11-13T00:00:00.0000000Z /' "$f"; done   # job logs: a timestamp per line

export PATH="$T/bin:$PATH" REPO=o/r SRC=$T/src STATE=$T/state GH_TOKEN=x T3_PROJECT=mcp:p SUPERVISOR_THREAD=mcp:22222222-2222-2222-2222-222222222222 \
       DISPATCH_THREAD=mcp:33333333-3333-3333-3333-333333333333 T3_MCP_FAKE=$T/bin/t3mcp WAKE_URL=http://127.0.0.1:9 MAIN_BRANCH=main
mkdir -p "$STATE"
dispatch() { : > "$FX/calls"; bash "$ROOT/scripts/ci/review-dispatch.sh" > "$T/out.$1" 2>&1 || { cat "$T/out.$1" >&2; fail "dispatcher run $1 exited non-zero"; }
  cp "$FX/calls" "$T/calls.$1"; }
count() { wc -l < "$T/calls.$1"; }
dispatch 1
dispatch 2
echo "gh invocations: run 1 $(count 1), run 2 $(count 2)"
[ "${API_BUDGET_SHOW:-}" ] && { cat "$STATE/dispatch.log" "$T/out.1" "$FX/t3" 2>/dev/null; ls "$STATE/sent"; sed 's/^/  1: /' "$T/calls.1"; sed 's/^/  2: /' "$T/calls.2"; }
lists=$(grep -c '^run list' "$T/calls.2" || true)
[ "$lists" -le 3 ] || fail "run 2 listed runs $lists times (one listing per filter set: review, CI dev, all)"
if grep -E "^api repos/o/r/actions/(runs/($RH1|$RH2)/jobs|jobs/(${RH1}2|${RH2}2)/logs)" "$T/calls.2"; then fail "run 2 fetched a completed run's jobs / log again"; fi
[ "$(count 1)" -le "${API_BUDGET_COLD:-20}" ] || fail "run 1: $(count 1) gh calls (budget ${API_BUDGET_COLD:-20})"
[ "$(count 2)" -le "${API_BUDGET_WARM:-8}" ] || fail "run 2: $(count 2) gh calls (budget ${API_BUDGET_WARM:-8})"
grep -q "MAIN ${H2:0:9}: finding(s) 1 → owner" "$STATE/dispatch.log" || fail "the blocked re-check's finding was not read: $(cat "$STATE/dispatch.log")"
# the cache rules directly (gh-cache.sh, the stored answers of runs 1-2): a stored completed run is answered without a call;
# a re-run is a new attempt — once the listing shows it queued again (a new updatedAt) its jobs are read again, never
# the stored answer of the previous attempt; an unfinished answer is never stored
(
  source "$ROOT/scripts/ci/gh-cache.sh"; ghc_init "$STATE/ghcache"
  gh run list -R o/r -w review.yml -e workflow_run -b main -L 5 --json databaseId >/dev/null
  : > "$FX/calls"; gh api "repos/o/r/actions/runs/$RH2/jobs" -q '.jobs | length' >/dev/null
  [ ! -s "$FX/calls" ] || fail "a stored completed run's jobs were fetched again: $(cat "$FX/calls")"
  jq --argjson id "$RH2" 'map(if .databaseId == $id then .status = "queued" | .conclusion = null | .updatedAt = "2026-11-13T01:00:00Z" else . end)' "$FX/runs.json" > "$T/r" && mv "$T/r" "$FX/runs.json"
  ghc_done; ghc_init "$STATE/ghcache"   # the next dispatcher run
  gh run list -R o/r -w review.yml -e workflow_run -b main -L 5 --json databaseId >/dev/null
  : > "$FX/calls"; gh api "repos/o/r/actions/runs/$RH2/jobs" >/dev/null
  grep -q "^api repos/o/r/actions/runs/$RH2/jobs" "$FX/calls" || fail "a re-run (new updatedAt, queued) was answered from the cache of the previous attempt"
  # a run no listing of this run shows: one record call decides (same updatedAt → the stored answer; re-run → fetched)
  ghc_done; ghc_init "$STATE/ghcache"
  : > "$FX/calls"; gh api "repos/o/r/actions/runs/$RH1/jobs" >/dev/null; gh api "repos/o/r/actions/runs/$RH1/jobs" >/dev/null
  [ "$(cat "$FX/calls")" = "api repos/o/r/actions/runs/$RH1" ] || fail "an unlisted stored run: expected one record call, got: $(cat "$FX/calls")"
  jq --argjson id "$RH1" 'map(if .databaseId == $id then .updatedAt = "2026-11-13T02:00:00Z" else . end)' "$FX/runs.json" > "$T/r" && mv "$T/r" "$FX/runs.json"
  ghc_done; ghc_init "$STATE/ghcache"
  : > "$FX/calls"; gh api "repos/o/r/actions/runs/$RH1/jobs" >/dev/null
  grep -q "^api repos/o/r/actions/runs/$RH1/jobs" "$FX/calls" || fail "an unlisted run whose record changed was answered from the cache"
  ghc_done
) || exit 1
echo "ok - stored completed runs are answered without a call; a re-run is read again; an unlisted run is checked by its record"

# review of baf73755e #3-#5 (and dev 730b3e2ca #3)
(
  source "$ROOT/scripts/ci/gh-cache.sh"; ghc_init "$STATE/ghcache"
  setrun() { jq --argjson id "$1" --arg u "$2" --arg c "$3" 'map(if .databaseId == $id then .status = "completed" | .conclusion = $c | .updatedAt = $u else . end)' "$FX/runs.json" > "$T/r" && mv "$T/r" "$FX/runs.json"; }
  old() { touch -d '-5 min' "$@"; }
  jobs_c() { gh api "repos/o/r/actions/runs/$RH1/jobs" -q '.jobs[1].conclusion'; }
  # #3: an answer kept for this run is not used once a newer listing shows the run re-run (completed again, failing)
  setrun "$RH1" 2026-11-13T03:00:00Z success
  gh run list -R o/r -w review.yml -e workflow_run -b main -L 5 --json databaseId >/dev/null
  [ "$(jobs_c)" = success ] || fail "setup: attempt 1 jobs"
  setrun "$RH1" 2026-11-13T04:00:00Z failure; jq '.jobs[1].conclusion = "failure"' "$FX/jobs-$RH1.json" > "$T/j" && mv "$T/j" "$FX/jobs-$RH1.json"
  old "$GHC_RUN"/list.*                     # the review listing is due again; the jobs answer is still within its 60 s
  gh run list -R o/r -w review.yml -e workflow_run -b main -L 5 --json databaseId >/dev/null
  [ "$(jobs_c)" = failure ] || fail "a kept jobs answer of the previous attempt was used after a newer listing showed the re-run"
  # #3: an OLDER listing (another filter set) that still shows the previous attempt does not decide over the newer one
  setrun "$RH1" 2026-11-13T05:00:00Z success; jq '.jobs[1].conclusion = "success"' "$FX/jobs-$RH1.json" > "$T/j" && mv "$T/j" "$FX/jobs-$RH1.json"
  gh run list -R o/r -L 50 --json databaseId >/dev/null; old "$GHC_RUN"/list.*                   # the all-runs listing: 05:00
  rm -f "$GHC_RUN"/api.*; jobs_c >/dev/null                                                     # stored for 05:00
  setrun "$RH1" 2026-11-13T06:00:00Z failure; jq '.jobs[1].conclusion = "failure"' "$FX/jobs-$RH1.json" > "$T/j" && mv "$T/j" "$FX/jobs-$RH1.json"
  rm -f "$GHC_RUN/list.$(ghc_key "o/r|review.yml|workflow_run|main")"*
  gh run list -R o/r -w review.yml -e workflow_run -b main -L 5 --json databaseId >/dev/null       # newer: 06:00
  [ "$(ghc_run_state "$RH1")" = "completed 2026-11-13T06:00:00Z" ] || fail "the run state came from the older listing: $(ghc_run_state "$RH1")"
  rm -f "$GHC_RUN"/api.*
  [ "$(jobs_c)" = failure ] || fail "a stored answer of the previous attempt was used (older listing decided)"
  # #4: an artifact that expired after it was listed: the next dispatcher run sees it expired (no kept presence)
  review_api() { gh api "repos/o/r/$1"; }
  source "$ROOT/scripts/ci/review-runs.sh"
  review_attested "$RH1" || fail "setup: the attestation is listed"
  gh api "repos/o/r/actions/artifacts/$RH1/zip" > "$T/z1"; [ -s "$T/z1" ] || fail "setup: zip"
  jq '.artifacts[0].expired = true' "$FX/artifacts-$RH1.json" > "$T/a" && mv "$T/a" "$FX/artifacts-$RH1.json"
  ghc_done; ghc_init "$STATE/ghcache"
  if review_attested "$RH1"; then fail "an expired attestation still counted (artifact listing kept across runs)"; fi
  : > "$FX/calls"; gh api "repos/o/r/actions/artifacts/$RH1/zip" > /dev/null
  grep -q "artifacts/$RH1/zip" "$FX/calls" || fail "a stored zip was answered for an artifact this run did not see unexpired"
  # #5: a request path longer than a file name: answered (bounded cache names), and answered even when nothing can be written
  long=$(printf 'b%.0s' $(seq 1 300))
  out=$(gh api "repos/o/r/actions/workflows/review.yml/runs?event=workflow_run&branch=$long&per_page=100&page=1") || fail "a long request path failed"
  jq -e '.workflow_runs' >/dev/null <<<"$out" || fail "a long request path: no answer"
  chmod 500 "$GHC_RUN" "$GHC_DIR/disk"
  out=$(gh api "repos/o/r/actions/runs/$RH2/jobs" -q '.jobs | length'); rc=$?
  chmod 700 "$GHC_RUN" "$GHC_DIR/disk"
  [ "$rc" = 0 ] && [ "$out" = 2 ] || fail "an answer that could not be written was not returned (rc $rc, '$out')"
  # review of 879c8c521 #3: a listing past its 60 s decides nothing — the record is asked (and here shows a re-run)
  ghc_done; ghc_init "$STATE/ghcache"
  gh run list -R o/r -w review.yml -e workflow_run -b main -L 5 --json databaseId >/dev/null          # shows 06:00 completed
  setrun "$RH1" 2026-11-13T07:00:00Z success; jq --argjson id "$RH1" 'map(if .databaseId == $id then .status = "queued" else . end)' "$FX/runs.json" > "$T/r" && mv "$T/r" "$FX/runs.json"
  old "$GHC_RUN"/list.*; : > "$FX/calls"; jobs_c >/dev/null
  grep -q "^api repos/o/r/actions/runs/$RH1\$" "$FX/calls" && grep -q "^api repos/o/r/actions/runs/$RH1/jobs" "$FX/calls" \
    || fail "an expired listing decided the run state: $(cat "$FX/calls")"
  # review of afb14f77d #4: a binary Actions download (a run's log zip) passes through byte for byte
  printf 'PK\003\004\000\000bin\000ary' > "$FX/runlogs.bin"
  [ "$(gh api "repos/o/r/actions/runs/$RH1/logs" | md5sum)" = "$(md5sum < "$FX/runlogs.bin")" ] || fail "a binary Actions answer was altered"
  ghc_done
) || exit 1
echo "ok - a re-run seen by a newer listing beats a kept answer, an older or expired listing; artifacts read fresh; long paths, unwritable caches and binary answers pass"
echo "dispatcher API budget: run 1 $(count 1) calls, run 2 $(count 2) calls (budgets ${API_BUDGET_COLD:-20} / ${API_BUDGET_WARM:-8})"
