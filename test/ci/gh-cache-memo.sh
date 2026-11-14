#!/usr/bin/env bash
# gh-cache.sh (the dispatcher's API memo, used by review-dispatch.sh and the contract scripts it runs) against a counting
# fake gh that answers from fixture files:
#   · identical reads within one dispatcher run are asked once (listings, jobs, records, workflow pages, artifacts lists);
#   · every write (gh run rerun / cancel / delete, gh workflow run, gh api -X …, git push) wipes the memo;
#   · nothing about a run outlives the dispatcher run: a re-run between two runs is always seen;
#   · a completed job's log is kept across runs by job id, byte for byte (NUL / binary bytes included), and only when a
#     jobs answer of the run showed the job completed; binary downloads pass through untouched and are never kept;
#   · approval evidence is never memoised (review of dev 4c4fc9d04, run 43495888972): gh is always the real gh; only
#     review-dispatch.sh's routing / notification readers use ghm (the memo), ghm is not exported, and no approval
#     script mentions it (enforced below). The reviewer's fixtures run WITHIN ONE dispatcher run with the memo holding
#     the passed attempt 1: a failed re-run revealed by the run record, a workflow page, a listing or a listing whose
#     write fails → review_verdict says blocked and review-passed.sh (as a dispatcher child) rejects it; likewise
#     across runs (reviews of b5de20258, c4ca24b30, c6dfe26bb);
#   · without a dispatcher run (no GHC_RUN_DIR) gh is the real gh, every call; an unwritable memo still answers.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
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
def load(f):
    try: return json.load(open(f"{FX}/{f}"))
    except (FileNotFoundError, json.JSONDecodeError): sys.exit(1)
def opt(names):
    for i, x in enumerate(a):
        if x in names and i + 1 < len(a): return a[i + 1]
    return None
def emit(o, q):
    if q is None: print(json.dumps(o)); return
    r = subprocess.run(["jq", "-rcS", q], input=json.dumps(o), capture_output=True, text=True)
    sys.stdout.write(r.stdout); sys.exit(r.returncode)
run = load("run.json")   # the one run: {"id", "title", "status", "conclusion", "updated", "attempt"}
if a[:2] == ["run", "list"]:
    if os.path.exists(f"{FX}/list-fails"): sys.stderr.write("HTTP 502\n"); sys.exit(1)
    fields = (opt(["--json"]) or "").split(",")
    known = "conclusion createdAt databaseId displayTitle event headBranch headSha name number startedAt status updatedAt url workflowDatabaseId workflowName".split()
    bad = [f for f in fields if f and f not in known]   # gh 2.45 (the host's): no "attempt"
    if bad: sys.stderr.write(f"Unknown JSON field: {bad[0]!r}\n"); sys.exit(1)
    r = {"databaseId": run["id"], "displayTitle": run["title"], "status": run["status"], "conclusion": run["conclusion"],
         "updatedAt": run["updated"], "event": "workflow_run", "headBranch": "main", "headSha": "x", "workflowName": "Review"}
    emit([{k: r.get(k) for k in fields if k}], opt(["-q", "--jq"])); sys.exit(0)
if a[:2] in (["run", "rerun"], ["run", "cancel"], ["run", "delete"], ["workflow", "run"]): sys.exit(0)
if a[0] == "api":
    if "-X" in a: sys.exit(0)
    q = opt(["-q", "--jq"])
    path = next(x for x in a[1:] if not x.startswith("-") and x != q)
    path = re.sub(r"^repos/[^/]+/[^/]+/", "", path)
    if path == f"actions/runs/{run['id']}":
        emit({"id": run["id"], "status": run["status"], "conclusion": run["conclusion"], "updated_at": run["updated"],
              "run_attempt": run["attempt"]}, q); sys.exit(0)
    if path == f"actions/runs/{run['id']}/jobs":
        done = run["status"] == "completed"; n = run["attempt"]; at = run.get("done_at", "2026-11-13T00:00:00Z")
        emit({"jobs": [
            {"id": n * 10 + 1, "name": "sheepdog / tests", "status": "completed" if done else "in_progress",
             "conclusion": "success" if done else None, "completed_at": at if done else None},
            {"id": n * 10 + 2, "name": "sheepdog / review", "status": "completed" if done else "in_progress",
             "conclusion": run["conclusion"], "completed_at": at if done else None,
             "steps": [{"name": "Review (blocking; x)", "conclusion": run["conclusion"]}]}]}, q); sys.exit(0)
    if path == f"actions/runs/{run['id']}/artifacts":
        emit({"artifacts": [{"name": "review-attestation", "id": run["attempt"], "expired": run.get("expired", False)}]}, q); sys.exit(0)
    m = re.fullmatch(r"actions/workflows/([^/?]+)/runs\??(.*)", path)
    if m:
        emit({"workflow_runs": [{"id": run["id"], "display_title": run["title"], "event": "workflow_run", "head_branch": "main",
              "path": ".github/workflows/review.yml", "status": run["status"], "conclusion": run["conclusion"]}]}, q); sys.exit(0)
    m = re.fullmatch(r"actions/jobs/(\d+)/logs", path)
    if m:
        f = f"{FX}/log-{m.group(1)}"
        if not os.path.exists(f): sys.exit(1)
        sys.stdout.buffer.write(open(f, "rb").read()); sys.exit(0)
    m = re.fullmatch(r"actions/(artifacts/\d+/zip|runs/\d+/logs)", path)
    if m: sys.stdout.buffer.write(open(f"{FX}/blob.bin", "rb").read()); sys.exit(0)
sys.exit(1)
PY
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
setrun() { # setrun <status> <conclusion|null> <updated> <attempt>
  jq -nc --arg s "$1" --arg c "$2" --arg u "$3" --argjson n "$4" \
    '{id: 7, title: "review x", status: $s, conclusion: (if $c == "null" then null else $c end), updated: $u, attempt: $n}' > "$FX/run.json"
}
calls() { grep -c "$1" "$FX/calls" || true; }
STATE=$T/state; mkdir -p "$STATE"
printf 'review-gate: PASS\n' > "$FX/log-12"
printf 'review-gate: BLOCKED #1 regression [must]: x\n' > "$FX/log-22"
printf 'PK\003\004\000\001\377\000bin\000ary\r\n' > "$FX/blob.bin"
LIST=(run list -R o/r -w review.yml -e workflow_run -b main -L 100 --json databaseId,displayTitle,status,conclusion)
JOBS=repos/o/r/actions/runs/7/jobs

# ── memo within one dispatcher run ──
source "$ROOT/scripts/ci/gh-cache.sh"
setrun completed success 2026-11-13T00:10:00Z 1
ghc_init "$STATE"; : > "$FX/calls"
ghm "${LIST[@]}" >/dev/null; [ "$(ghm "${LIST[@]}" -q '.[0].conclusion')" = success ] || fail "listing -q"
ghm api "$JOBS" >/dev/null; [ "$(ghm api "$JOBS" -q '.jobs[1].conclusion')" = success ] || fail "jobs -q"
ghm api repos/o/r/actions/runs/7 >/dev/null; ghm api repos/o/r/actions/runs/7 -q .status >/dev/null
ghm api "repos/o/r/actions/workflows/review.yml/runs?event=workflow_run&branch=main&per_page=100&page=1" >/dev/null
ghm api "repos/o/r/actions/workflows/review.yml/runs?event=workflow_run&branch=main&per_page=100&page=1" >/dev/null
[ "$(wc -l < "$FX/calls")" = 4 ] || fail "identical reads within one run were asked again: $(cat "$FX/calls")"
# gh — what every approval reads through — is the real gh, every call, inside a dispatcher run too
: > "$FX/calls"; gh api "$JOBS" >/dev/null; gh api "$JOBS" >/dev/null; gh "${LIST[@]}" >/dev/null; gh "${LIST[@]}" >/dev/null
[ "$(wc -l < "$FX/calls")" = 4 ] || fail "gh answered from the memo: $(cat "$FX/calls")"
[ "$(ghm "${LIST[@]}" -q '.[0] | {status, conclusion}')" = '{"conclusion":"success","status":"completed"}' ] || fail "-q output differs from gh's (compact, sorted)"
echo "ok - ghm: identical reads within one dispatcher run, one call each; gh: always the real call"

# ── every write wipes the memo ──
for w in "gh run rerun 7 -R o/r" "gh run cancel 7 -R o/r" "gh run delete 7 -R o/r" "gh workflow run review.yml -R o/r" \
         "gh api -X POST repos/o/r/actions/runs/7/rerun" "gh pr create" "git push"; do
  ghm api "$JOBS" >/dev/null; : > "$FX/calls"
  if [ "$w" = "git push" ]; then
    git init -q --bare "$T/r.git" 2>/dev/null || true; git init -q "$T/w" 2>/dev/null || true
    git -C "$T/w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
    git -C "$T/w" push -q "$T/r.git" HEAD:refs/heads/main
  else $w >/dev/null 2>&1 || true; fi
  ghm api "$JOBS" >/dev/null
  [ "$(calls "actions/runs/7/jobs$")" = 1 ] || fail "after '$w' the memo answered: $(cat "$FX/calls")"
done
echo "ok - rerun / cancel / delete / workflow run / gh api -X / other gh commands / git push wipe the memo"

# ── nothing about a run outlives the dispatcher run ──
ghc_done; [ ! -d "$GHC_RUN_DIR" ] || fail "the memo directory outlived the run"
setrun completed failure 2026-11-13T00:20:00Z 2   # re-run between the two dispatcher runs: failed
ghc_init "$STATE"; : > "$FX/calls"
[ "$(ghm api "$JOBS" -q '.jobs[1].conclusion')" = failure ] || fail "the next dispatcher run got the previous attempt's jobs"
[ "$(ghm "${LIST[@]}" -q '.[0].conclusion')" = failure ] || fail "the next dispatcher run got the previous listing"
find "$STATE/ghcache" -path "$GHC_RUN_DIR" -prune -o -type f -print | grep -v '/logs/' && fail "something other than job logs is stored across runs"
echo "ok - the next dispatcher run asks again (a re-run between runs is always seen); only job logs are stored"

# ── completed jobs' logs: by job id, byte for byte; only once a jobs answer showed the job completed ──
ghc_done; ghc_init "$STATE"; setrun completed failure 2026-11-13T00:25:00Z 4
printf 'partial log\n' > "$FX/log-42"
: > "$FX/calls"; ghm api repos/o/r/actions/jobs/42/logs > "$T/l0"
[ -e "$STATE/ghcache/logs/final.42" ] && fail "a log was stored though no jobs answer of this run showed the job completed"
printf 'ok\000NUL\377\376 bytes\r\nreview-gate: BLOCKED #1 x\n\000' > "$FX/log-42"
ghm api "$JOBS" >/dev/null   # shows job 42 completed (2026-11-13: long ago)
ghm api repos/o/r/actions/jobs/42/logs > "$T/l1"
cmp -s "$FX/log-42" "$T/l1" || fail "the unconfirmed prefix was promoted after completion instead of refetching the final log"
[ "$(calls 'actions/jobs/42/logs$')" = 2 ] || fail "completion did not trigger a second log fetch"
ghc_done; ghc_init "$STATE"; : > "$FX/calls"
ghm api repos/o/r/actions/jobs/42/logs > "$T/l2"
[ ! -s "$FX/calls" ] || fail "a stored completed job's log was fetched again: $(cat "$FX/calls")"
cmp -s <(printf 'partial log\n') "$T/l0" && cmp -s "$FX/log-42" "$T/l1" && cmp -s "$FX/log-42" "$T/l2" || fail "a job log was altered (NUL / binary bytes)"
cmp -s "$FX/log-42" "$STATE/ghcache/logs/final.42" || fail "the stored log differs from GitHub's"
# a job that completed less than two minutes ago: its log may still be incomplete — not stored
setrun in_progress null 2026-11-13T00:30:00Z 3; printf 'partial\n' > "$FX/log-32"
jq --arg t "$(date -u +%FT%TZ)" '.status = "completed" | .conclusion = "success" | .done_at = $t' "$FX/run.json" > "$T/r" && mv "$T/r" "$FX/run.json"
ghm api "$JOBS" >/dev/null; ghm api repos/o/r/actions/jobs/32/logs >/dev/null
[ -e "$STATE/ghcache/logs/final.32" ] && fail "the log of a job completed seconds ago was stored"
# binary downloads pass through byte for byte and are never kept
: > "$FX/calls"
ghm api repos/o/r/actions/artifacts/3/zip > "$T/z1"; ghm api repos/o/r/actions/artifacts/3/zip > "$T/z2"; ghm api repos/o/r/actions/runs/7/logs > "$T/z3"
cmp -s "$FX/blob.bin" "$T/z1" && cmp -s "$FX/blob.bin" "$T/z2" && cmp -s "$FX/blob.bin" "$T/z3" || fail "a binary download was altered"
[ "$(wc -l < "$FX/calls")" = 3 ] || fail "a binary download was answered from a memo: $(cat "$FX/calls")"
echo "ok - completed job logs kept by job id, byte for byte; recent / unconfirmed logs and binary downloads never kept"

# ── approval evidence is never memoised: the reviewer's fixtures WITHIN ONE dispatcher run (review of d95e275d3 /
#    4c4fc9d04 #1; earlier: 8e5891359 #1-#3, c4ca24b30 #1-#2) ──
review_api() { gh api "repos/o/r/$1"; }   # review-passed.sh's own definition: the approval consumers read through gh
REVIEW_DEFAULT_BRANCH=main
source "$ROOT/scripts/ci/review-runs.sh"
source "$ROOT/scripts/ci/review-coverage.sh"
for via in record page listing failed-write none; do
  ghc_done; ghc_init "$STATE"
  setrun completed success 2026-11-13T00:10:00Z 1
  # the dispatcher's routing reads fill the memo with attempt 1 (listings, jobs, record, page); the consumers pass it
  ghm "${LIST[@]}" >/dev/null; ghm run list -R o/r -L 60 --json databaseId,status >/dev/null; ghm api "$JOBS" >/dev/null
  ghm api repos/o/r/actions/runs/7 >/dev/null; ghm api "repos/o/r/actions/workflows/review.yml/runs?event=workflow_run&branch=main&per_page=100&page=1" >/dev/null
  [ "$(review_verdict 7)" = pass ] || fail "($via) setup: attempt 1 passes"
  review_attested 7 || fail "($via) setup: attested"
  # the re-run fails — in the SAME dispatcher run (no ghc_done); a fresh read reveals it first via <via>
  setrun completed failure 2026-11-13T00:20:00Z 2
  case "$via" in
    record) [ "$(gh api repos/o/r/actions/runs/7 -q .conclusion)" = failure ] || fail "record" ;;
    page) review_runs completed | jq -e 'select(.conclusion == "failure")' >/dev/null || fail "page" ;;
    listing) [ "$(gh run list -R o/r -L 60 --json databaseId,conclusion -q '.[0].conclusion')" = failure ] || fail "listing" ;;
    failed-write) chmod 500 "$GHC_RUN_DIR"   # a listing of another filter that cannot be written
      [ "$(ghm run list -R o/r -L 50 --json databaseId,conclusion -q '.[0].conclusion')" = failure ] || fail "failed write: listing" ;;
    none) ;;
  esac
  : > "$FX/calls"
  v=$(review_verdict 7) || v=none
  chmod 700 "$GHC_RUN_DIR"
  [ "$v" = blocked ] || fail "($via) review_verdict in the same dispatcher run: '$v' (the memoised attempt-1 jobs were served)"
  [ "$(calls "actions/runs/7/jobs$")" = 1 ] || fail "($via) review_verdict did not read the jobs from GitHub: $(cat "$FX/calls")"
  # ghm itself still answers attempt 1 here (routing may lag one dispatcher run) — the consumers never read it
  [ "$(ghm api "$JOBS" -q '.jobs[1].conclusion')" = success ] || fail "fixture: the memo holds attempt 1"
done
# an artifact that expires during the run is seen expired by the consumer
ghc_done; setrun completed success 2026-11-13T00:10:00Z 1; ghc_init "$STATE"; ghm api repos/o/r/actions/runs/7/artifacts >/dev/null
review_attested 7 || fail "attested"
jq '.expired = true' "$FX/run.json" > "$T/r" && mv "$T/r" "$FX/run.json"
if review_attested 7; then fail "an expired attestation still counted (memoised artifacts list)"; fi
echo "ok - review_verdict / review_attested read GitHub: a failed re-run in the same dispatcher run (record, page, listing, failed write) blocks"

# review-passed.sh as the dispatcher runs it (a child, memo filled with the passed attempt 1, same dispatcher run)
git init -q "$T/clone"; cd "$T/clone"
SHA=$(git -c user.name=t -c user.email=t@t commit -q --allow-empty -m x && git rev-parse HEAD)
jq --arg t "review $SHA" '.title = $t | .expired = false' "$FX/run.json" > "$T/r" && mv "$T/r" "$FX/run.json"
jq -nc --arg h "$SHA" '{head: $h, base: $h, kind: "review"}' > "$T/review-attestation.json"; (cd "$T" && python3 -c "
import zipfile; z = zipfile.ZipFile('$FX/blob.bin', 'w'); z.write('review-attestation.json'); z.close()")
for via in record page listing failed-write; do
  ghc_done; ghc_init "$STATE"
  jq '.status = "completed" | .conclusion = "success" | .attempt = 1' "$FX/run.json" > "$T/r" && mv "$T/r" "$FX/run.json"
  ghm api "$JOBS" >/dev/null; ghm api repos/o/r/actions/runs/7/artifacts >/dev/null; ghm "${LIST[@]}" >/dev/null
  REPO=o/r bash "$ROOT/scripts/ci/review-passed.sh" "$SHA" >/dev/null 2>&1 || fail "($via) setup: review-passed.sh passes attempt 1"
  jq '.status = "completed" | .conclusion = "failure" | .attempt = 2' "$FX/run.json" > "$T/r" && mv "$T/r" "$FX/run.json"
  case "$via" in
    record) gh api repos/o/r/actions/runs/7 >/dev/null ;;
    page) gh api "repos/o/r/actions/workflows/review.yml/runs?event=workflow_run&branch=main&per_page=100&page=1" >/dev/null ;;
    listing) gh run list -R o/r -L 60 --json databaseId,conclusion >/dev/null ;;
    failed-write) chmod 500 "$GHC_RUN_DIR"; ghm run list -R o/r -L 50 --json databaseId,conclusion >/dev/null ;;
  esac
  rc=0; REPO=o/r bash "$ROOT/scripts/ci/review-passed.sh" "$SHA" >/dev/null 2>&1 || rc=$?
  chmod 700 "$GHC_RUN_DIR"
  [ "$rc" != 0 ] || fail "($via) review-passed.sh (a dispatcher child) approved the failed re-run in the same dispatcher run"
done
cd "$ROOT"
echo "ok - review-passed.sh as a dispatcher child rejects a failed re-run seen in the same run (record, page, listing, failed write)"

# ── the split, enforced: only the dispatcher's routing reads use ghm; no approval path can reach the memo ──
( bash -c 'declare -F ghm ghc_api ghc_fetch >/dev/null' ) && fail "ghm is visible to child scripts (exported)"
for f in "$ROOT"/scripts/ci/*.sh; do
  case "$(basename "$f")" in gh-cache.sh|review-dispatch.sh|test-*) continue ;; esac
  if grep -nE '\bghm\b|GHC_RUN_DIR|ghc_(api|fetch|out)' "$f"; then fail "$(basename "$f") reaches the memo (approval scripts read GitHub)"; fi
done
D=$ROOT/scripts/ci/review-dispatch.sh
ALLOWED=" review_list all_runs_list dev_round_running findings notes_of recheck_base preexisting_record main_infra dev_infra main_culprits_api "   # main_infra: the log excerpt of a supervisor notice; dev_infra: the review job id naming an alert; main_culprits_api: which findings of a dev review are main's (routing; landing is review-passed.sh's)
bad=$(awk -v ok="$ALLOWED" '/^[a-z_]+\(\) \{/ { fn = $1; sub(/\(\)$/, "", fn) } /^[^ #]/ && !/^[a-z_]+\(\) \{/ && !/^ / { fn = "" }
  /(^|[^a-z_])ghm / && !/^[[:space:]]*#/ { if (index(ok, " " fn " ") == 0) print NR ": " (fn == "" ? "(top level)" : fn) }' "$D")
[ -z "$bad" ] || fail "ghm used outside the routing / notification readers of review-dispatch.sh: $bad"
for fn in review-passed.sh merge-branch.sh run_verdict review_jobs; do
  grep -qE "ghm .*$fn|$fn.*ghm " "$D" && fail "$fn is wired to the memo"
done
echo "ok - ghm only in review-dispatch.sh's routing readers ($ALLOWED); approval scripts never reach the memo"

# ── a wipe that cannot delete the memo disables it for the run (review of 43c8601d9 #2) ──
ghc_done; setrun completed success 2026-11-13T00:10:00Z 1; ghc_init "$STATE"
ghm api "$JOBS" >/dev/null; setrun completed failure 2026-11-13T00:20:00Z 2
( rm() { return 1; }; export -f rm; gh run rerun 7 -R o/r 2> "$T/wipe.err" ) || fail "a write failed though the memo could be disabled"
grep -q 'invalidation failed' "$T/wipe.err" && [ -e "$GHC_RUN_DIR.disabled" ] || fail "a failed wipe was not recorded"
[ "$(ghm api "$JOBS" -q '.jobs[1].conclusion')" = failure ] || fail "the memo answered after a failed wipe"
ghc_done; [ ! -e "$GHC_RUN_DIR.disabled" ] || fail "the disabled marker outlived the run"
echo "ok - a wipe that cannot delete the memo disables it for the rest of the run"

# ── outside a dispatcher run: the real gh every time; an unwritable memo still answers ──
ghc_done
( unset GHC_RUN_DIR; : > "$FX/calls"; ghm api "$JOBS" >/dev/null; ghm api "$JOBS" >/dev/null
  [ "$(calls "actions/runs/7/jobs$")" = 2 ] || fail "outside a dispatcher run the memo answered" ) || exit 1
ghc_init "$STATE"; chmod 500 "$GHC_RUN_DIR" "$STATE/ghcache/logs"
out=$(ghm api "$JOBS" -q '.jobs | length') && [ "$out" = 2 ] || fail "an unwritable memo: no answer ('$out')"
[ "$(ghm "${LIST[@]}" -q 'length')" = 1 ] || fail "an unwritable memo: no listing"
cmp -s "$FX/log-12" <(ghm api repos/o/r/actions/jobs/12/logs) || fail "an unwritable store: the log"
chmod 700 "$GHC_RUN_DIR" "$STATE/ghcache/logs"; ghc_done
echo "ok - no dispatcher run: uncached; unwritable memo / store: still the real answers"
