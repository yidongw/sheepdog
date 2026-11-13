#!/usr/bin/env bash
# gh-cache.sh (the dispatcher's API memo, used by review-dispatch.sh and the contract scripts it runs) against a counting
# fake gh that answers from fixture files:
#   · identical reads within one dispatcher run are asked once (listings, jobs, records, workflow pages, artifacts lists);
#   · every write (gh run rerun / cancel / delete, gh workflow run, gh api -X …, git push) wipes the memo;
#   · nothing about a run outlives the dispatcher run: a re-run between two runs is always seen;
#   · a completed job's log is kept across runs by job id, byte for byte (NUL / binary bytes included), and only when a
#     jobs answer of the run showed the job completed; binary downloads pass through untouched and are never kept;
#   · the approval consumers (review_verdict, review_attested, review-passed.sh) see the current attempt of a re-run,
#     whichever source revealed the re-run first — the reviewer's reproductions of dev b5de20258 (run 43487250364:
#     run record, workflow page, another filter's listing, a failing listing) and of the earlier rounds;
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
gh "${LIST[@]}" >/dev/null; [ "$(gh "${LIST[@]}" -q '.[0].conclusion')" = success ] || fail "listing -q"
gh api "$JOBS" >/dev/null; [ "$(gh api "$JOBS" -q '.jobs[1].conclusion')" = success ] || fail "jobs -q"
gh api repos/o/r/actions/runs/7 >/dev/null; gh api repos/o/r/actions/runs/7 -q .status >/dev/null
gh api "repos/o/r/actions/workflows/review.yml/runs?event=workflow_run&branch=main&per_page=100&page=1" >/dev/null
gh api "repos/o/r/actions/workflows/review.yml/runs?event=workflow_run&branch=main&per_page=100&page=1" >/dev/null
[ "$(wc -l < "$FX/calls")" = 4 ] || fail "identical reads within one run were asked again: $(cat "$FX/calls")"
[ "$(gh "${LIST[@]}" -q '.[0] | {status, conclusion}')" = '{"conclusion":"success","status":"completed"}' ] || fail "-q output differs from gh's (compact, sorted)"
echo "ok - identical reads within one dispatcher run: one call each"

# ── every write wipes the memo ──
for w in "gh run rerun 7 -R o/r" "gh run cancel 7 -R o/r" "gh run delete 7 -R o/r" "gh workflow run review.yml -R o/r" \
         "gh api -X POST repos/o/r/actions/runs/7/rerun" "gh pr create" "git push"; do
  gh api "$JOBS" >/dev/null; : > "$FX/calls"
  if [ "$w" = "git push" ]; then
    git init -q --bare "$T/r.git" 2>/dev/null || true; git init -q "$T/w" 2>/dev/null || true
    git -C "$T/w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
    git -C "$T/w" push -q "$T/r.git" HEAD:refs/heads/main
  else $w >/dev/null 2>&1 || true; fi
  gh api "$JOBS" >/dev/null
  [ "$(calls "actions/runs/7/jobs$")" = 1 ] || fail "after '$w' the memo answered: $(cat "$FX/calls")"
done
echo "ok - rerun / cancel / delete / workflow run / gh api -X / other gh commands / git push wipe the memo"

# ── nothing about a run outlives the dispatcher run ──
ghc_done; [ ! -d "$GHC_RUN_DIR" ] || fail "the memo directory outlived the run"
setrun completed failure 2026-11-13T00:20:00Z 2   # re-run between the two dispatcher runs: failed
ghc_init "$STATE"; : > "$FX/calls"
[ "$(gh api "$JOBS" -q '.jobs[1].conclusion')" = failure ] || fail "the next dispatcher run got the previous attempt's jobs"
[ "$(gh "${LIST[@]}" -q '.[0].conclusion')" = failure ] || fail "the next dispatcher run got the previous listing"
find "$STATE/ghcache" -path "$GHC_RUN_DIR" -prune -o -type f -print | grep -v '/logs/' && fail "something other than job logs is stored across runs"
echo "ok - the next dispatcher run asks again (a re-run between runs is always seen); only job logs are stored"

# ── completed jobs' logs: by job id, byte for byte; only once a jobs answer showed the job completed ──
ghc_done; ghc_init "$STATE"; setrun completed failure 2026-11-13T00:25:00Z 4
printf 'ok\000NUL\377\376 bytes\r\nreview-gate: BLOCKED #1 x\n\000' > "$FX/log-42"
: > "$FX/calls"; gh api repos/o/r/actions/jobs/42/logs > "$T/l0"
[ -e "$STATE/ghcache/logs/42" ] && fail "a log was stored though no jobs answer of this run showed the job completed"
gh api "$JOBS" >/dev/null   # shows job 42 completed (2026-11-13: long ago)
gh api repos/o/r/actions/jobs/42/logs > "$T/l1"
ghc_done; ghc_init "$STATE"; : > "$FX/calls"
gh api repos/o/r/actions/jobs/42/logs > "$T/l2"
[ ! -s "$FX/calls" ] || fail "a stored completed job's log was fetched again: $(cat "$FX/calls")"
cmp -s "$FX/log-42" "$T/l0" && cmp -s "$FX/log-42" "$T/l1" && cmp -s "$FX/log-42" "$T/l2" || fail "a job log was altered (NUL / binary bytes)"
cmp -s "$FX/log-42" "$STATE/ghcache/logs/42" || fail "the stored log differs from GitHub's"
# a job that completed less than two minutes ago: its log may still be incomplete — not stored
setrun in_progress null 2026-11-13T00:30:00Z 3; printf 'partial\n' > "$FX/log-32"
jq --arg t "$(date -u +%FT%TZ)" '.status = "completed" | .conclusion = "success" | .done_at = $t' "$FX/run.json" > "$T/r" && mv "$T/r" "$FX/run.json"
gh api "$JOBS" >/dev/null; gh api repos/o/r/actions/jobs/32/logs >/dev/null
[ -e "$STATE/ghcache/logs/32" ] && fail "the log of a job completed seconds ago was stored"
# binary downloads pass through byte for byte and are never kept
: > "$FX/calls"
gh api repos/o/r/actions/artifacts/3/zip > "$T/z1"; gh api repos/o/r/actions/artifacts/3/zip > "$T/z2"; gh api repos/o/r/actions/runs/7/logs > "$T/z3"
cmp -s "$FX/blob.bin" "$T/z1" && cmp -s "$FX/blob.bin" "$T/z2" && cmp -s "$FX/blob.bin" "$T/z3" || fail "a binary download was altered"
[ "$(wc -l < "$FX/calls")" = 3 ] || fail "a binary download was answered from a memo: $(cat "$FX/calls")"
echo "ok - completed job logs kept by job id, byte for byte; recent / unconfirmed logs and binary downloads never kept"

# ── the approval consumers see the current attempt of a re-run (reviews of 8e5891359 #1-#3 and earlier) ──
review_api() { gh api "repos/o/r/$1"; }
REVIEW_DEFAULT_BRANCH=main
source "$ROOT/scripts/ci/review-runs.sh"
source "$ROOT/scripts/ci/review-coverage.sh"
for via in record page other-filter failing-listing none; do
  ghc_done; ghc_init "$STATE"
  setrun completed success 2026-11-13T00:10:00Z 1
  # dispatcher run A: everything a consumer reads about attempt 1 (the successful one)
  gh "${LIST[@]}" >/dev/null; gh run list -R o/r -L 60 --json databaseId,status >/dev/null
  [ "$(review_verdict 7)" = pass ] || fail "($via) setup: attempt 1 passes"
  review_attested 7 || fail "($via) setup: attested"
  ghc_done
  # the re-run fails; dispatcher run B learns it first from <via>, then asks the consumers
  setrun completed failure 2026-11-13T00:20:00Z 2
  ghc_init "$STATE"
  case "$via" in
    record) [ "$(gh api repos/o/r/actions/runs/7 -q .conclusion)" = failure ] || fail "record" ;;
    page) review_runs completed | jq -e 'select(.conclusion == "failure")' >/dev/null || fail "page" ;;
    other-filter) [ "$(gh run list -R o/r -L 60 --json databaseId,conclusion -q '.[0].conclusion')" = failure ] || fail "other filter" ;;
    failing-listing) touch "$FX/list-fails"; gh "${LIST[@]}" >/dev/null 2>&1 && fail "the failing listing was answered" ;;
    none) ;;
  esac
  v=$(review_verdict 7) || v=none
  [ "$v" = blocked ] || fail "($via) review_verdict of the failed re-run: '$v' (the previous attempt's jobs were served)"
  rm -f "$FX/list-fails"
  # and the reverse order within the same dispatcher run is consistent too: the consumers asked again see attempt 2
  [ "$(review_verdict 7)" = blocked ] || fail "($via) second consumer"
done
# an artifact that expired between two dispatcher runs is seen expired
ghc_done; setrun completed success 2026-11-13T00:10:00Z 1; ghc_init "$STATE"; review_attested 7 || fail "attested"
ghc_done; jq '.expired = true' "$FX/run.json" > "$T/r" && mv "$T/r" "$FX/run.json"; ghc_init "$STATE"
if review_attested 7; then fail "an expired attestation still counted in the next dispatcher run"; fi
echo "ok - review_verdict / review_attested see the current attempt after a re-run seen via record, page, another filter, a failing listing"

# review-passed.sh as the dispatcher runs it (a child: the exported memo); a passed attempt 1, then a failed re-run
git init -q "$T/clone"; cd "$T/clone"
SHA=$(git -c user.name=t -c user.email=t@t commit -q --allow-empty -m x && git rev-parse HEAD)
jq --arg t "review $SHA" '.title = $t | .expired = false' "$FX/run.json" > "$T/r" && mv "$T/r" "$FX/run.json"
jq -nc --arg h "$SHA" '{head: $h, base: $h, kind: "review"}' > "$T/review-attestation.json"; (cd "$T" && python3 -c "
import zipfile; z = zipfile.ZipFile('$FX/blob.bin', 'w'); z.write('review-attestation.json'); z.close()")
ghc_done; ghc_init "$STATE"
REPO=o/r bash "$ROOT/scripts/ci/review-passed.sh" "$SHA" >/dev/null 2>&1 || fail "setup: review-passed.sh passes attempt 1"
ghc_done; jq '.status = "completed" | .conclusion = "failure" | .attempt = 2' "$FX/run.json" > "$T/r" && mv "$T/r" "$FX/run.json"
ghc_init "$STATE"
gh api repos/o/r/actions/runs/7 >/dev/null   # the record shows the failed re-run first
if REPO=o/r bash "$ROOT/scripts/ci/review-passed.sh" "$SHA" >/dev/null 2>&1; then fail "review-passed.sh approved the failed re-run"; fi
cd "$ROOT"
echo "ok - review-passed.sh (a child of the dispatcher run) rejects the failed re-run"

# ── outside a dispatcher run: the real gh every time; an unwritable memo still answers ──
ghc_done
( unset GHC_RUN_DIR; : > "$FX/calls"; gh api "$JOBS" >/dev/null; gh api "$JOBS" >/dev/null
  [ "$(calls "actions/runs/7/jobs$")" = 2 ] || fail "outside a dispatcher run the memo answered" ) || exit 1
ghc_init "$STATE"; chmod 500 "$GHC_RUN_DIR" "$STATE/ghcache/logs"
out=$(gh api "$JOBS" -q '.jobs | length') && [ "$out" = 2 ] || fail "an unwritable memo: no answer ('$out')"
[ "$(gh "${LIST[@]}" -q 'length')" = 1 ] || fail "an unwritable memo: no listing"
cmp -s "$FX/log-12" <(gh api repos/o/r/actions/jobs/12/logs) || fail "an unwritable store: the log"
chmod 700 "$GHC_RUN_DIR" "$STATE/ghcache/logs"; ghc_done
echo "ok - no dispatcher run: uncached; unwritable memo / store: still the real answers"
