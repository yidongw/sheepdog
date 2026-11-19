#!/usr/bin/env bash
# A green devfix that cannot land on main because the chain below its blocked base S is not covered, while no blocked
# commit of main..S lacks its repair (11-19 tralyx e04f635cd: the repair of aaedf6a65 below it had landed on main only;
# devfix/e04f635cd140 sat 3 h, its fixer ended at 18:25Z, and every later blocked commit got "dev fixer for e04f635cd
# still active: no second fixer"). The WHOLE review-dispatch.sh on a fake repository (fake gh, T3 stubbed, as in
# review-dispatch-devfix-machinery.sh):
#   · the one-fixer slot is freed once S's fixer thread ended while its devfix is not covered: the next blocked commit
#     gets its fixer (logged once);
#   · the uncovered devfix is re-asked every run; not covered on a second run with its fixer ended, it goes to dev —
#     and when that conflicts, S is UNREPAIRED: the devfix is stuck and S takes the route of every unrepaired block
#     (its authors told, then the strongest fixer);
#   · once the chain below S is covered, the devfix still lands on main.
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
# `t3 thread start` → a new thread id; `t3 thread show <tid>` → "<tid> <state>": running, or what $FX/t3state says (a test
# ends the fixers that way)
echo "t3 $*" >> "$FX/t3"
if [ "${1:-} ${2:-}" = "thread send" ] && [ -e "$FX/t3fail" ]; then echo "t3: transport down" >&2; exit 1; fi   # a delivery failure
case "${1:-} ${2:-}" in
  "thread start") n=$(( $(cat "$FX/t3n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/t3n"; cat > /dev/null
                  printf 'Started thread mcp:aaaaaaaa-0000-4000-8000-%012d\n' "$n" ;;   # a real thread id: the receipt holds it
  "thread show") echo "$3 $(cat "$FX/t3state" 2>/dev/null || echo running)" ;;
  *) echo '{"status":"running"}' ;;
esac
SH
chmod +x "$T/bin/gh" "$T/bin/t3mcp" "$T/bin/t3"

git init -q --bare -b main "$T/remote.git"; git init -q -b main "$T/w"; cd "$T/w"; git remote add origin "$T/remote.git"
g() { git -c user.name=t -c user.email=t@t "$@"; }
TH=mcp:11111111-1111-1111-1111-111111111111
c() { mkdir -p "$(dirname "$1")"; echo "$RANDOM$RANDOM" >> "$1"; g add -A; g commit -q -m "change $1" -m "${2:-}
Loop: adhoc/test
Thread: $TH
Verify:
- [x] fails before / passes after: t"; git rev-parse HEAD; }
mkdir -p .github/workflows; echo "sheepdog: {}" > .github/sheepdog.yml
printf 'jobs:\n  sheepdog:\n    uses: yidongw/sheepdog/.github/workflows/review.yml@%040d\n' 1 > .github/workflows/review.yml
A=$(c src/a.ts); g push -q origin main
# dev: D1, then D2 changing the same file (a devfix of D1 merged into dev conflicts with it)
g checkout -q -b dev; D1=$(c src/d1.ts); D2=$(c src/d1.ts); g push -q origin dev

RUNS=(); id=100
run() { # run <title> <head sha> <conclusion> <review step conclusion>
  id=$((id + 1))
  RUNS+=("$(jq -nc --argjson id "$id" --arg t "$1" --arg hs "$2" --arg c "$3" \
    '{databaseId: $id, displayTitle: $t, path: ".github/workflows/review.yml", workflowName: "Review", event: "workflow_run",
      headBranch: "main", headSha: $hs, status: "completed", conclusion: $c, createdAt: "2026-11-19T00:00:00Z",
      updatedAt: "2026-11-19T00:10:00Z", number: $id, name: "x"}')")
  jq -nc --argjson id "$id" --arg rc "${4:-$3}" '{jobs: [{id: ($id * 10 + 1), name: "sheepdog / tests", status: "completed", conclusion: "success"},
    {id: ($id * 10 + 2), name: "sheepdog / review", status: "completed", conclusion: (if $rc == "skipped" then "success" else $rc end),
     steps: [{name: "Review (blocking; x)", conclusion: $rc}]}]}' > "$FX/jobs-$id.json"
}
publish() { (IFS=,; echo "[${RUNS[*]}]") | jq 'reverse' > "$FX/runs.json"; }
blocked_run() { # blocked_run <sha> <review base> → its dev review blocked, attested <base>..<sha>; sets RID
  run "review $1" "$1" failure; RID=$id
  printf '2026-11-19T00:00:00.0000000Z review-range: %s %s\n2026-11-19T00:00:00.0000000Z review-gate: reviewing aaaaaaaa..bbbbbbbb\n2026-11-19T00:00:00.0000000Z review-gate: FINDING #1 route=fixer commit=%s — x\n2026-11-19T00:00:00.0000000Z review-gate: BLOCKED #1 regression [should]: it drops rows\n2026-11-19T00:00:00.0000000Z evidence: src/d1.ts:1 x\n' "$2" "$1" "$1" > "$FX/log-${RID}2.txt"
  echo "{\"artifacts\":[{\"name\":\"review-attestation\",\"id\":$RID}]}" > "$FX/artifacts-$RID.json"
  jq -nc --arg h "$1" --arg b "$2" '{head: $h, base: $b, kind: "review"}' > "$FX/attest-$RID.json"
}
blocked_run "$D1" "$A"; RD1=$RID
blocked_run "$D2" "$D1"
publish

export PATH="$T/bin:$PATH" REPO=o/r SRC=$T/src STATE=$T/state GH_TOKEN=x T3_PROJECT=mcp:p SUPERVISOR_THREAD=mcp:22222222-2222-2222-2222-222222222222 \
       DISPATCH_THREAD=mcp:33333333-3333-3333-3333-333333333333 T3_MCP_FAKE=$T/bin/t3mcp T3_MCP=$T/bin/t3mcp WAKE_URL=http://127.0.0.1:9 MAIN_BRANCH=main
mkdir -p "$STATE/sent"
git clone -q "$T/remote.git" "$T/src"
dispatch() { bash "$ROOT/scripts/ci/review-dispatch.sh" > "$T/out" 2>&1 || { cat "$T/out" >&2; fail "dispatcher exited non-zero"; }; }
main_at() { git -C "$T/remote.git" rev-parse main; }
L=$STATE/dispatch.log
dispatch   # D1 (oldest) gets the fixer and the slot; D2 waits for the slot
[ -e "$STATE/sent/$D1.fixer-blocked" ] || fail "setup: no fixer for the blocked D1: $(cat "$L")"
[ "$(cat "$STATE/dev-fixer.active")" = "$D1" ] || fail "setup: D1 does not hold the fixer slot"
[ ! -e "$STATE/sent/$D2.fixer-blocked" ] || fail "setup: D2 got a second fixer"
grep -q "dev fixer for ${D1:0:9} still active: no second fixer for blocked ${D2:0:9}" "$L" || fail "setup: D2 not deferred: $(tail -3 "$L")"

# D1's fixer pushes its devfix (green trusted tests) and ends; the proof below D1 is missing (its attestation unreadable)
g checkout -q -B fx "$D1"; FXH=$(c src/d1.ts "Review-Fix-Of: $D1
Hotfix: review fix of ${D1:0:9}"); g push -q -f origin "fx:refs/heads/devfix/${D1:0:12}"
run "review $FXH" "$FXH" success skipped; publish
mv "$FX/attest-$RD1.json" "$FX/attest-$RD1.json.off"
echo interrupted > "$FX/t3state"; touch -d '-10 min' "$STATE/sent/$D1.fixer-blocked"
dispatch   # 1st run that sees it: not covered — logged, it waits (the proof may still come)
grep -q "devfix devfix/${D1:0:12} ${FXH:0:9}: the commits below ${D1:0:9} are not covered" "$L" || fail "no coverage log: $(tail -3 "$L")"
[ "$(main_at)" = "$A" ] || fail "an uncovered devfix landed on main"
[ ! -e "$STATE/sent/$FXH.devfix-stuck" ] || fail "the devfix was judged stuck on the first run that saw it uncovered"

dispatch   # 2nd run: S's fixer ended, its devfix still not covered
[ -e "$STATE/sent/$D2.fixer-blocked" ] || fail "the ended fixer of D1 kept the slot (its devfix cannot land): D2 got no fixer: $(tail -5 "$L")"
grep -q "dev fixer(s) for ${D1:0:9} ended and its fix ${FXH:0:9} on devfix/${D1:0:12} cannot land on main (the commits below ${D1:0:9} are not covered): slot freed" "$L" \
  || fail "no slot-freed log: $(tail -5 "$L")"
echo "ok - the slot is freed when S's fixer ended and its devfix cannot land: the next blocked commit gets its fixer"
[ -e "$STATE/sent/$FXH.devfix-stuck" ] || fail "an uncovered devfix that conflicts with dev was not judged stuck: $(tail -5 "$L")"
grep -q "devfix devfix/${D1:0:12} ${FXH:0:9} (fix of ${D1:0:9}): cannot land on main (the commits below it are still not covered and its fixer ended) and conflicts with dev — ${D1:0:9} is unrepaired" "$L" \
  || fail "no stuck log: $(tail -5 "$L")"
[ "$(git -C "$T/remote.git" rev-parse dev)" = "$D2" ] || fail "dev moved although the merge conflicts"
git -C "$T/remote.git" rev-parse -q --verify "refs/heads/devfix/${D1:0:12}" >/dev/null || fail "the stuck devfix branch was deleted"

dispatch   # D1 is unrepaired now: the route of every unrepaired block — its authors first
ls "$STATE/sent/$D1".fixfailed* >/dev/null 2>&1 || fail "the authors of the unrepaired D1 were not told: $(tail -5 "$L")"
DEV_ESCALATE_AFTER_MIN=0 dispatch   # … then the strongest fixer
[ -e "$STATE/sent/$D1.fixer-devstrong-1" ] || fail "no strongest fixer for the unrepaired D1: $(tail -5 "$L")"
echo "ok - a devfix that lands neither on main nor on dev leaves S unrepaired: authors told, then the strongest fixer"
[ "$(grep -c "dev fixer(s) for ${D1:0:9} .*slot freed" "$L")" = 1 ] || fail "D1's slot-freed line was logged more than once"

# the proof below D1 comes back: the devfix is re-asked every run and lands on main
mv "$FX/attest-$RD1.json.off" "$FX/attest-$RD1.json"
dispatch
[ "$(main_at)" = "$FXH" ] || fail "the devfix did not land on main once covered: $(tail -5 "$L")"
echo "ok - the devfix lands on main once the chain below S is covered"
