#!/usr/bin/env bash
# 11-18 tralyx (13:06Z → 11-19 01:48Z, 12.5 h without a dev merge): the devfix a5f8f91c1 of the blocked e596eb3a5 failed its
# trusted tests (run 44309218296: ONE test, deterministically — the fixture the reviewed change broke). The testsfail fixer
# ran the focused tests elsewhere, reported "they pass, no changes", ONE fixfailed notice went to the supervisor — and the
# dispatcher did nothing else: the ended fixer, the delivered notice and the parked red devfix branch all counted as done.
# The WHOLE review-dispatch.sh on a fake repository (fake gh, T3 and the wake relay stubbed, as in
# review-dispatch-devfix-machinery.sh):
#   A · the testsfail fixer's task names the failed test files from the trusted log and pins it to the failing head
#       (reproduce there first); no automatic re-run. It ends without pushing a new head → unresolved, not done: the
#       notice says so and the strongest fixer (STRONG_FIXER_*) takes it over at once, with what failed.
#   C · any other fixfailed notice: still no repair DEV_ESCALATE_AFTER_MIN after it, nobody at work → the strongest fixer;
#       each one that ends without a repair is followed by another at the escalated effort, the supervisor told from
#       level 3; a live strongest fixer is never doubled; a Review-Fix-Of: repair on dev ends it.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
TOP=$(mktemp -d); trap 'rm -rf "$TOP"' EXIT

setup() { # setup <name> → a fresh fake world in $TOP/<name>: main A, dev D1 blocked by its review, the dispatcher's first run
  T=$TOP/$1; FX=$T/fx; mkdir -p "$FX" "$T/bin"; export FX
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
  # T3 stubs: every launch gets its own thread id; `t3 thread show` answers $FX/t3state.<tid>, else $FX/t3state (running by
  # default); messages are kept
  cat > "$T/bin/t3mcp" <<'SH'
#!/usr/bin/env bash
echo "$1 $2" >> "$FX/t3"
case "$1" in
  t3_thread_launch) n=$(( $(cat "$FX/n" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$FX/n"
                    echo "{\"threadId\":\"mcp:aaaaaaaa-0000-0000-0000-000000000$n\"}" ;;
  *) echo '{"status":"running"}' ;;
esac
SH
  cat > "$T/bin/t3" <<'SH'
#!/usr/bin/env bash
echo "t3 $*" >> "$FX/t3"
case "${1:-} ${2:-}" in
  "thread show") f=$FX/t3state.$3; [ -e "$f" ] || f=$FX/t3state; echo "$3 $(cat "$f" 2>/dev/null || echo running)" ;;
  "thread start") n=$(( $(cat "$FX/n" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$FX/n"; cat > "$FX/msg-start-$n"
                  echo "mcp:bbbbbbbb-0000-0000-0000-000000000$n" ;;
  "thread send") cat >> "$FX/msg-send"; echo '{"status":"running"}' ;;
  *) echo '{"status":"running"}' ;;
esac
SH
  chmod +x "$T/bin/gh" "$T/bin/t3mcp" "$T/bin/t3"
  git init -q --bare -b main "$T/remote.git"; git init -q -b main "$T/w"; cd "$T/w"; git remote add origin "$T/remote.git"
  mkdir -p .github/workflows; echo "sheepdog: {}" > .github/sheepdog.yml
  printf 'jobs:\n  sheepdog:\n    uses: yidongw/sheepdog/.github/workflows/review.yml@%040d\n' 1 > .github/workflows/review.yml
  A=$(c src/a.ts); g push -q origin main
  g checkout -q -b dev; D1=$(c src/d1.ts); g push -q origin dev
  RUNS=(); id=100
  run "review $D1" completed failure failure success; RD1=$id
  printf '2026-11-13T00:00:00.0000000Z review-range: %s %s\n2026-11-13T00:00:00.0000000Z review-gate: reviewing aaaaaaaa..bbbbbbbb\n2026-11-13T00:00:00.0000000Z review-gate: FINDING #1 route=fixer commit=%s — x\n2026-11-13T00:00:00.0000000Z review-gate: BLOCKED #1 regression [should]: d1 drops rows\n2026-11-13T00:00:00.0000000Z evidence: src/d1.ts:1 x\n' "$A" "$D1" "$D1" > "$FX/log-${RD1}2.txt"
  echo "{\"artifacts\":[{\"name\":\"review-attestation\",\"id\":$RD1}]}" > "$FX/artifacts-$RD1.json"
  jq -nc --arg h "$D1" --arg b "$A" '{head: $h, base: $b, kind: "review"}' > "$FX/attest-$RD1.json"
  publish
  export PATH="$T/bin:$PATH" REPO=o/r SRC=$T/src STATE=$T/state GH_TOKEN=x T3_PROJECT=mcp:p SUPERVISOR_THREAD=mcp:22222222-2222-2222-2222-222222222222 \
         DISPATCH_THREAD=mcp:33333333-3333-3333-3333-333333333333 T3_MCP=$T/bin/t3mcp WAKE_URL=http://127.0.0.1:9 MAIN_BRANCH=main \
         FIXER_ENDED_GRACE_MIN=0 STRONG_FIXER_PROVIDER=claudeAgent STRONG_FIXER_MODEL=strong-model STRONG_FIXER_EFFORT=medium STRONG_FIXER_EFFORT_ESCALATED=high
  mkdir -p "$STATE/sent"
  git clone -q "$T/remote.git" "$T/src"
  dispatch   # the blocked review of D1 → its fixer
  [ -s "$STATE/sent/$D1.fixer-blocked" ] || fail "setup: no fixer for the blocked D1: $(cat "$STATE/dispatch.log")"
  echo completed > "$FX/t3state.$(head -1 "$STATE/sent/$D1.fixer-blocked")"   # it pushes its devfix (below) and ends
}
g() { git -c user.name=t -c user.email=t@t "$@"; }
TH=mcp:11111111-1111-1111-1111-111111111111
c() { mkdir -p "$(dirname "$1")"; echo "$RANDOM" >> "$1"; [ -z "${2:-}" ] || { mkdir -p "$(dirname "$2")"; echo "$RANDOM" >> "$2"; }
  g add -A; g commit -q -m "change $1" -m "${3:-}
Loop: adhoc/test
Thread: $TH
Verify:
- [x] fails before / passes after: t"; git rev-parse HEAD; }
devfix() { # devfix <files…> → FXH: a fix of D1 changing them, pushed to devfix/<D1>
  g checkout -q -B fx "$D1"; FXH=$(c "$1" "${2:-}" "Review-Fix-Of: $D1
Hotfix: review fix of ${D1:0:9}"); g push -q -f origin "fx:refs/heads/devfix/${D1:0:12}"; }
run() { # run <title> <status> <conclusion> <review step conclusion> <tests conclusion> [<tests status>] → a new run $id
  id=$((id + 1)); mkjobs "$id" "$4" "$5" "${6:-completed}" "$((id * 10 + 1))"
  RUNS+=("$(jq -nc --argjson id "$id" --arg t "$1" --arg hs "${1#* }" --arg st "$2" --arg c "$3" \
    '{databaseId: $id, displayTitle: $t, path: ".github/workflows/review.yml", workflowName: "Review", event: "workflow_run", headBranch: "main",
      headSha: $hs, status: $st, conclusion: $c, createdAt: "2026-11-13T00:00:00Z", updatedAt: "2026-11-13T00:10:00Z", number: $id, name: "x"}')")
}
mkjobs() { # mkjobs <run> <review step conclusion> <tests conclusion> <tests status> <tests job id>
  jq -nc --argjson tid "$5" --argjson rid "$(( $1 * 10 + 2 ))" --arg rc "$2" --arg tc "$3" --arg ts "$4" '{jobs: [
    {id: $tid, name: "sheepdog / tests", status: $ts, conclusion: (if $ts == "completed" then $tc else null end)},
    {id: $rid, name: "sheepdog / review", status: "completed", conclusion: (if $rc == "skipped" then "skipped" elif $rc == "failure" then "failure" else "success" end),
     steps: [{name: "Review (blocking; x)", conclusion: $rc}]}]}' > "$FX/jobs-$1.json"
}
failing_log() { printf '2026-11-18T13:01:00.0000000Z \033[31m FAIL \033[39m  shared  %s > suite > it keeps the row\n2026-11-18T13:01:00.0000000Z  Test Files  1 failed | 972 passed (973)\n' "$2" > "$FX/log-$1.txt"; }
publish() { (IFS=,; echo "[${RUNS[*]}]") | jq 'reverse' > "$FX/runs.json"; }
dispatch() { bash "$ROOT/scripts/ci/review-dispatch.sh" > "$T/out" 2>&1 || { cat "$T/out" >&2; fail "dispatcher exited non-zero"; }; }
reruns() { grep -c "^run rerun $1" "$FX/calls" || true; }
main_at() { git -C "$T/remote.git" rev-parse main; }
old() { touch -d '-61 min' "$@"; }
moves_branch() { grep -E '(checkout -B|switch -C) ' | grep -v 'never git checkout -B / git switch -C' | grep -q .; }   # stdin: a task

# ── A · a5f8f91c1 replayed: a failing test in a file the fix did not touch is real until reproduced otherwise ──
setup a
devfix src/d1.ts; run "review $FXH" completed failure skipped failure; RF=$id; failing_log "$((RF * 10 + 1))" test/evm-self-call.test.ts; publish
dispatch
[ -s "$STATE/sent/$FXH.fixer-testsfail" ] || fail "A: no testsfail fixer: $(tail -3 "$STATE/dispatch.log")"
[ "$(reruns "$RF")" = 0 ] || fail "A: the red tests were re-run instead of reproduced"
TASK=$FX/msg-start-$(cat "$FX/n")
grep -q 'Failed test file(s): test/evm-self-call.test.ts' "$TASK" || fail "A: the testsfail task does not name the failed test file: $(head -5 "$TASK")"
grep -q "git rev-parse HEAD .*(it must print $FXH)" "$TASK" && grep -q 'REPRODUCE FIRST, at exactly the failing commit' "$TASK" || fail "A: the task does not pin reproduction to the failing head"
grep -q "thread start .*--worktree origin/devfix/${D1:0:12}" "$FX/t3" || fail "A: the testsfail fixer's worktree is not the failing devfix head"
! moves_branch < "$TASK" || fail "A: the testsfail task moves a shared branch name (re-check of 1f0e4acc9 #1)"
echo "ok - a red devfix: its testsfail fixer gets the failed test files and must reproduce them at the failing head (no re-run)"
echo completed > "$FX/t3state"; dispatch   # it ended without pushing anything ("the focused tests pass")
[ -e "$STATE/sent/$D1.fixfailed.0" ] || fail "A: no fixfailed notice: $(tail -3 "$STATE/dispatch.log")"
grep -q 'That is unresolved: the strongest fixer agent takes it over now' "$FX/msg-send" || fail "A: the notice does not say it is unresolved"
grep -q "${FXH:0:9}: its testsfail fixer ended without pushing a new head — unresolved, not done" "$STATE/dispatch.log" || fail "A: not logged as unresolved"
dispatch
[ -s "$STATE/sent/$D1.fixer-devstrong-1" ] || fail "A: the testsfail fixer ended without a push and the strongest fixer did not take over: $(tail -5 "$STATE/dispatch.log")"
L=$(grep '^t3_thread_launch ' "$FX/t3" | tail -1 | cut -d' ' -f2-)
jq -e '.modelSelection == {instanceId:"claudeAgent",model:"strong-model",options:[{id:"effort",value:"medium"}]} and .workspaceStrategy.baseRef == "origin/dev"' <<<"$L" >/dev/null || fail "A: strongest fixer launch: $L"
jq -r .message <<<"$L" | grep -q "fix $FXH (devfix/${D1:0:12}) failed the trusted tests; failed test file(s): test/evm-self-call.test.ts" || fail "A: the strongest fixer's task does not say what failed: $(jq -r .message <<<"$L" | head -20)"
jq -r .message <<<"$L" | grep -q "Review-Fix-Of: $D1" || fail "A: the strongest fixer's task does not name the repair trailer"
! jq -r .message <<<"$L" | moves_branch || fail "A: the strongest fixer's task moves a shared branch name (re-check of 1f0e4acc9 #1)"
[ "$(reruns "$RF")" = 0 ] || fail "A: re-run"
echo "ok - a testsfail fixer that ends without a push is unresolved: the strongest fixer takes over at once, told what failed"

# ── C · a fixfailed notice is never the end: the strongest fixer after DEV_ESCALATE_AFTER_MIN, escalating, never silent ──
setup c; echo completed > "$FX/t3state"   # D1's fixer ended without pushing anything; every later fixer ends at once
dispatch
ls "$STATE/sent/$D1".fixfailed* >/dev/null 2>&1 || fail "C: no fixfailed notice for the fixer that ended without a fix: $(tail -3 "$STATE/dispatch.log")"
dispatch
! ls "$STATE/sent/$D1".fixer-devstrong-* >/dev/null 2>&1 || fail "C: the strongest fixer was woken before DEV_ESCALATE_AFTER_MIN"
old "$STATE/sent/$D1".fixfailed*; dispatch
[ -s "$STATE/sent/$D1.fixer-devstrong-1" ] || fail "C: 60 min after the fixfailed notice, still no repair, nobody at work — no strongest fixer: $(tail -5 "$STATE/dispatch.log")"
grep '^t3_thread_launch ' "$FX/t3" | tail -1 | grep -q '"value":"medium"' || fail "C: level 1 is not at STRONG_FIXER_EFFORT"
grep -q "${D1:0:9}: still no repair .* the strongest fixer (level 1" "$STATE/dispatch.log" || fail "C: the escalation is not logged"
echo "ok - still unrepaired 60 min after a fixfailed notice: the strongest fixer (STRONG_FIXER_EFFORT), on dev"
dispatch
! [ -e "$STATE/sent/$D1.fixer-devstrong-2" ] || fail "C: level 2 within DEV_ESCALATE_AFTER_MIN of level 1"
old "$STATE/sent/$D1.fixer-devstrong-1"; dispatch
[ -s "$STATE/sent/$D1.fixer-devstrong-2" ] || fail "C: level 1 ended without a repair and nothing followed: $(tail -3 "$STATE/dispatch.log")"
grep '^t3_thread_launch ' "$FX/t3" | tail -1 | grep -q '"value":"high"' || fail "C: level 2 is not at the escalated effort"
! ls "$STATE/sent/$D1".devstrong-failed* >/dev/null 2>&1 || fail "C: the supervisor told at level 2 already"
old "$STATE/sent/$D1.fixer-devstrong-2"; dispatch
[ -s "$STATE/sent/$D1.fixer-devstrong-3" ] || fail "C: no level 3"
ls "$STATE/sent/$D1".devstrong-failed* >/dev/null 2>&1 || fail "C: the supervisor was not told that the strongest fixers keep failing"
echo "ok - each strongest fixer that ends without a repair is followed by another at the escalated effort; the supervisor told from level 3"
echo running > "$FX/t3state"; old "$STATE/sent/$D1.fixer-devstrong-3"; dispatch
! [ -e "$STATE/sent/$D1.fixer-devstrong-4" ] || fail "C: a second strongest fixer while one is at work"
cd "$T/w"; g fetch -q origin; g checkout -q -B dv origin/dev; c src/d1.ts "" "Review-Fix-Of: $D1" >/dev/null; g push -q origin dv:dev
echo completed > "$FX/t3state"; old "$STATE/sent/$D1.fixer-devstrong-3"; dispatch
! [ -e "$STATE/sent/$D1.fixer-devstrong-4" ] || fail "C: a repaired commit was escalated again"
grep -q 'dev: every blocked commit has its repair' "$STATE/dispatch.log" || fail "C: the repair was not seen: $(tail -3 "$STATE/dispatch.log")"
echo "ok - a live strongest fixer is never doubled; a Review-Fix-Of: repair on dev ends the escalation"

# ── E · an author still inside the window the reviewer gave them owns S: no escalation over them (re-check of 1f0e4acc9 #2) ──
setup e; echo completed > "$FX/t3state"
dispatch
ls "$STATE/sent/$D1".fixfailed* >/dev/null 2>&1 || fail "E: setup: no fixfailed notice"
echo "author $(date +%s)" > "$STATE/sent/$D1.route-author.mcp_44444444-4444-4444-4444-444444444444"
old "$STATE/sent/$D1".fixfailed*; dispatch
! ls "$STATE/sent/$D1".fixer-devstrong-* >/dev/null 2>&1 || fail "E: escalated over an author inside their repair window"
echo "author $(( $(date +%s) - ${AUTHOR_FIX_WINDOW_SEC:-3600} - 60 ))" > "$STATE/sent/$D1.route-author.mcp_44444444-4444-4444-4444-444444444444"
dispatch
[ -s "$STATE/sent/$D1.fixer-devstrong-1" ] || fail "E: the author window closed and nothing escalated: $(tail -3 "$STATE/dispatch.log")"
echo "ok - an open author window holds the escalation; once it closes, the strongest fixer"

# re-check of 1f0e4acc9 #1: no fixer task creates or resets a fixed branch name — names are shared by every worktree
! moves_branch < "$ROOT/scripts/ci/review-dispatch.sh" || fail "a fixer task still moves a shared branch name"
echo "ok - fixer tasks stay on the branch wake_fixer created for their worktree"

