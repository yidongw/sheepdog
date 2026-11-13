#!/usr/bin/env bash
# A review fix lands on its trusted tests alone (devfix/<S>: no review runs there) — so it must never carry review machinery
# (review of dev a171d3396 #1/#2: a pin-only repair landed on green tests, and the next main run selected the
# replacement workflow before any check inside it). The WHOLE review-dispatch.sh on a fake repository (fake gh, T3 and
# the wake relay stubbed, as in review-dispatch-api-budget.sh):
#   · a devfix that changes only code lands on main (fast-forward);
#   · a devfix that changes .github/workflows/review.yml (the sheepdog pin), .github/sheepdog/tests.sh or scripts/ci/
#     is NOT landed: logged once, the authors told to push it through a full review;
#   · a code-only repair of a blocked base S that itself changes the pin is not landed (review of dev c1dcca119 #1/#2),
#     nor a repair whose merge of main rolls main's newer pin back (an evil merge the combined diff hides: #3);
#   · merge-branch.sh refuses a tests-only approval that changes review machinery, and still merges one that does not.
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
# `t3 thread show <tid>` → "<tid> <state>": running, or what $FX/t3state says (a test ends a fixer that way)
echo "t3 $*" >> "$FX/t3"
if [ "${1:-} ${2:-}" = "thread show" ]; then echo "$3 $(cat "$FX/t3state" 2>/dev/null || echo running)"; else echo '{"status":"running"}'; fi
SH
chmod +x "$T/bin/gh" "$T/bin/t3mcp" "$T/bin/t3"


git init -q --bare -b main "$T/remote.git"; git init -q -b main "$T/w"; cd "$T/w"; git remote add origin "$T/remote.git"
g() { git -c user.name=t -c user.email=t@t "$@"; }
TH=mcp:11111111-1111-1111-1111-111111111111
c() { mkdir -p "$(dirname "$1")"; echo "$RANDOM" >> "$1"; g add -A; g commit -q -m "change $1" -m "${2:-}
Loop: adhoc/test
Thread: $TH
Verify:
- [x] fails before / passes after: t"; git rev-parse HEAD; }
mkdir -p .github/workflows; echo "sheepdog: {}" > .github/sheepdog.yml
printf 'jobs:\n  sheepdog:\n    uses: yidongw/sheepdog/.github/workflows/review.yml@%040d\n' 1 > .github/workflows/review.yml
A=$(c src/a.ts); g tag deployed; g push -q origin main --tags
g checkout -q -b dev; D1=$(c src/d1.ts); g push -q origin dev
fix() { # fix <file> → a devfix of D1 changing <file>, pushed to devfix/<D1>
  g checkout -q -B fx "$D1"; FXH=$(c "$1" "Review-Fix-Of: $D1
Hotfix: review fix of ${D1:0:9}"); g push -q -f origin "fx:refs/heads/devfix/$D1"; }

RUNS=(); id=100
run() { # run <title> <path> <event> <branch> <head sha> <status> <conclusion> <review step conclusion>
  id=$((id + 1))
  local wn=Review; [ "$2" = .github/workflows/ci.yml ] && wn=CI
  RUNS+=("$(jq -nc --argjson id "$id" --arg t "$1" --arg p "$2" --arg wn "$wn" --arg ev "$3" --arg br "$4" --arg hs "$5" --arg st "$6" --arg c "$7" \
    '{databaseId: $id, displayTitle: $t, path: $p, workflowName: $wn, event: $ev, headBranch: $br, headSha: $hs, status: $st,
      conclusion: $c, createdAt: "2026-11-13T00:00:00Z", updatedAt: "2026-11-13T00:10:00Z", number: $id, name: "x"}')")
  jq -nc --argjson id "$id" --arg rc "${8:-$7}" '{jobs: [{id: ($id * 10 + 1), name: "sheepdog / tests", status: "completed", conclusion: "success"},
    {id: ($id * 10 + 2), name: "sheepdog / review", status: "completed", conclusion: (if $rc == "skipped" then "success" else $rc end),
     steps: [{name: "Review (blocking; x)", conclusion: $rc}]}]}' > "$FX/jobs-$id.json"
}
R=.github/workflows/review.yml
publish() { (IFS=,; echo "[${RUNS[*]}]") | jq 'reverse' > "$FX/runs.json"; }
run "review $D1" $R workflow_run main "$D1" completed failure; RD1=$id
printf '2026-11-13T00:00:00.0000000Z review-range: %s %s\n2026-11-13T00:00:00.0000000Z review-gate: FINDING #1 route=fixer commit=%s — x\n2026-11-13T00:00:00.0000000Z review-gate: BLOCKED #1 regression [should]: d1 drops rows\n2026-11-13T00:00:00.0000000Z evidence: src/d1.ts:1 x\n' "$A" "$D1" "$D1" > "$FX/log-${RD1}2.txt"
publish

export PATH="$T/bin:$PATH" REPO=o/r SRC=$T/src STATE=$T/state GH_TOKEN=x T3_PROJECT=mcp:p SUPERVISOR_THREAD=mcp:22222222-2222-2222-2222-222222222222 \
       DISPATCH_THREAD=mcp:33333333-3333-3333-3333-333333333333 T3_MCP_FAKE=$T/bin/t3mcp WAKE_URL=http://127.0.0.1:9 MAIN_BRANCH=main
mkdir -p "$STATE/sent"
git clone -q "$T/remote.git" "$T/src"
dispatch() { bash "$ROOT/scripts/ci/review-dispatch.sh" > "$T/out" 2>&1 || { cat "$T/out" >&2; fail "dispatcher exited non-zero"; }; }
main_at() { git -C "$T/remote.git" rev-parse main; }
dispatch   # the blocked review of D1 → a fixer (stub) is woken: sent/D1.fixer-blocked
[ -e "$STATE/sent/$D1.fixer-blocked" ] || fail "setup: no fixer for the blocked D1: $(cat "$STATE/dispatch.log")"

for f in .github/workflows/review.yml .github/sheepdog/tests.sh scripts/ci/check.sh reviewer/src/x.ts; do
  fix "$f"; run "review $FXH" $R workflow_run main "$FXH" completed success skipped; publish
  dispatch
  [ "$(main_at)" = "$A" ] || fail "a devfix changing $f landed on main on its tests alone"
  grep -q "devfix devfix/$D1 ${FXH:0:9}: changes review machinery ($f )" "$STATE/dispatch.log" || fail "no log for the machinery devfix ($f): $(tail -3 "$STATE/dispatch.log")"
  n=$(grep -c "${FXH:0:9}: changes review machinery" "$STATE/dispatch.log"); dispatch
  [ "$(grep -c "${FXH:0:9}: changes review machinery" "$STATE/dispatch.log")" = "$n" ] || fail "the machinery devfix was reported again"
done
echo "ok - a devfix changing the workflow pin, the trusted test list, a contract script or the reviewer is not landed"
fix src/d1.ts; run "review $FXH" $R workflow_run main "$FXH" completed success skipped; publish
dispatch
[ "$(main_at)" = "$FXH" ] || fail "a code-only devfix did not land: $(tail -3 "$STATE/dispatch.log")"
echo "ok - a code-only devfix still lands on its tests"

# review of dev c1dcca119 #1/#2: the blocked base S itself changes the pin; a code-only repair on it is not landed
cd "$T/w"; g fetch -q origin; g checkout -q -B dev2 origin/main
printf 'jobs:\n  sheepdog:\n    uses: yidongw/sheepdog/.github/workflows/review.yml@%040d\n' 2 > .github/workflows/review.yml
D2=$(c .github/workflows/review.yml); g push -q -f origin "dev2:refs/heads/dev"
blocked() { # blocked <sha> → its dev review blocked; the dispatcher wakes a fixer for it
  run "review $1" $R workflow_run main "$1" completed failure; local r=$id
  printf '2026-11-13T00:00:00.0000000Z review-range: %s %s\n2026-11-13T00:00:00.0000000Z review-gate: FINDING #1 route=fixer commit=%s — x\n2026-11-13T00:00:00.0000000Z review-gate: BLOCKED #1 regression [should]: it drops rows\n2026-11-13T00:00:00.0000000Z evidence: src/x.ts:1 x\n' "$1" "$1" "$1" > "$FX/log-${r}2.txt"
  publish; dispatch; [ -e "$STATE/sent/$1.fixer-blocked" ] || { fail "setup: no fixer for the blocked ${1:0:9}: $(tail -3 "$STATE/dispatch.log")"; }; }
blocked "$D2"
g checkout -q -B fx "$D2"; FXH=$(c src/fix2.ts "Review-Fix-Of: $D2
Hotfix: review fix of ${D2:0:9}"); g push -q -f origin "fx:refs/heads/devfix/$D2"
M0=$(main_at); run "review $FXH" $R workflow_run main "$FXH" completed success skipped; publish; dispatch
[ "$(main_at)" = "$M0" ] || fail "a code-only repair landed its blocked base's workflow pin change"
grep -q "${FXH:0:9}: changes review machinery (.github/workflows/review.yml )" "$STATE/dispatch.log" || fail "no machinery log for the blocked base's pin: $(tail -3 "$STATE/dispatch.log")"
echo "ok - a code-only repair whose blocked base changes the pin is not landed"
# review of dev c1dcca119 #3: main moved the pin (1 → 3); a repair merges main but keeps the OLD pin (an evil merge:
# the combined diff hides it) — the landing tree would roll main's pin back, so it is not landed
g push -q origin --delete "devfix/$D2"; rm -rf "$STATE"/sent/*.fixer-* "$STATE/fixer-gate" "$STATE/dev-fixer.active"   # the earlier fixers are done (one at a time)
g checkout -q -B hot origin/main
printf 'jobs:\n  sheepdog:\n    uses: yidongw/sheepdog/.github/workflows/review.yml@%040d\n' 3 > .github/workflows/review.yml
MH=$(c .github/workflows/review.yml "Hotfix: pin 3"); g push -q origin "hot:refs/heads/main"
g checkout -q -B dev3 "$M0"; D3=$(c src/d3.ts); g push -q -f origin "dev3:refs/heads/dev"
blocked "$D3"
g checkout -q -B fx "$D3"; c src/fix3.ts "Review-Fix-Of: $D3
Hotfix: review fix of ${D3:0:9}" >/dev/null
g merge -q --no-ff "$MH" -m "merge main" -m "Review-Fix-Of: $D3"; git checkout -q HEAD^1 -- .github/workflows/review.yml
g commit -q --amend --no-edit; FXH=$(git rev-parse HEAD); g push -q -f origin "fx:refs/heads/devfix/$D3"
[ -z "$(git log --format= --name-only --cc -1 "$FXH" | grep -F .github/ || true)" ] || fail "setup: the evil merge shows in its combined diff"
run "review $FXH" $R workflow_run main "$FXH" completed success skipped; publish; dispatch
[ "$(main_at)" = "$MH" ] || fail "a repair whose merge rolls main's pin back landed"
grep -q "${FXH:0:9}: changes review machinery (.github/workflows/review.yml )" "$STATE/dispatch.log" || fail "no machinery log for the rollback: $(tail -3 "$STATE/dispatch.log")"
echo "ok - a repair whose merge rolls main's workflow pin back is not landed"

# merge-branch.sh: a tests-only approval (stub review-passed.sh) with / without review machinery
MB=$T/mb; mkdir -p "$MB"; cp "$ROOT/scripts/ci/merge-branch.sh" "$ROOT/scripts/ci/review-machinery.sh" "$MB/"
printf '#!/usr/bin/env bash\necho tests-only-fix > "$REVIEW_KIND_OUT"\n' > "$MB/review-passed.sh"
cd "$T/src"; git fetch -q origin; g checkout -q -B mbtest origin/main
g checkout -q -b fxm; c .github/workflows/review.yml "Review-Fix-Of: $D1" >/dev/null; g push -q origin fxm
if out=$(bash "$MB/merge-branch.sh" fxm 2>&1); then fail "merge-branch.sh landed review machinery on a tests-only approval: $out"; fi
grep -q 'changes review machinery' <<<"$out" || fail "merge-branch.sh: unexpected refusal: $out"
g checkout -q -B fxc origin/main; c src/ok.ts "Review-Fix-Of: $D1" >/dev/null; g push -q origin fxc
out=$(bash "$MB/merge-branch.sh" fxc 2>&1) || fail "merge-branch.sh refused a code-only tests-only fix: $out"
echo "ok - merge-branch.sh: a tests-only approval never lands review machinery; a code-only one still merges"
