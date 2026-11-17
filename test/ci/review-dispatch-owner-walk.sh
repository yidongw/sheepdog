#!/usr/bin/env bash
# Every blocked dev commit without its repair gets an owner (owner 11-17). The coverage chain (review-coverage.sh) needs
# an effective Review-Fix-Of: repair on the head for EVERY commit of main..dev whose verdict is blocked; tralyx 11-16/17
# left such commits with no fixer and no notice, and dev silently could not land. The WHOLE review-dispatch.sh runs on a
# fake repository (fake gh with run attempts, T3 stubbed; nothing real is reached):
#   (a) a blocked commit followed by a "merge main into dev" whose review passed (a66a062c9): the blocked one gets a fixer
#       on the devfix fast path (its run concluded cancelled: the dispatcher cancelled its tests);
#   (b) a blocked commit that waited for the one fixer slot (7caac614a): once the slot holder's repair is on dev, the
#       waiting commit gets its fixer — the next review never re-reports it;
#   (c) a green devfix of S that cannot land on main because a blocked commit below S is repaired only on dev above S
#       (856137bb9): it is merged into dev (its repair counts there) and the branch deleted, instead of holding the slot;
#       and a fixer woken for a commit with an unrepaired block below it pushes to dev, not devfix/;
#   (d) a round the commit gates refused before the reviewer ran (no verdict): its fixer (key "gate") writes the record on
#       main as a Hotfix and takes no dev fixer slot;
#   (e) a rerun whose attempt 2 BLOCKED after attempt 1 had no verdict (8bab832c9, run 44021700721): the verdict gets
#       its own fixer — also from the state an older dispatcher left (a "blocked" fixer + notice of attempt 1);
#   orphan: a blocked commit nobody can own any more → the supervisor, once.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D=${OWNER_WALK_DISPATCHER:-$ROOT/scripts/ci/review-dispatch.sh}
fail() { echo "FAIL: $*" | cut -c1-300 >&2; [ -n "${OWNER_WALK_KEEP_GOING:-}" ] || exit 1; }   # KEEP_GOING: report every scenario (fails-before runs)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FX/calls"
exec python3 "$FAKEGH" "$@"
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
runs = load("runs.json", [])
if a[:2] == ["run", "list"]:
    wf, ev, br = opt(["-w"]), opt(["-e"]), opt(["-b"])
    rs = runs
    if wf: rs = [r for r in rs if r["path"].endswith("/" + wf) or r["workflowName"] == wf]
    if ev: rs = [r for r in rs if r["event"] == ev]
    if br: rs = [r for r in rs if r["headBranch"] == br]
    rs = rs[: int(opt(["-L"]) or 20)]
    fields = (opt(["--json"]) or "").split(",")
    emit([{k: r.get(k) for k in fields if k} for r in rs], opt(["-q", "--jq"]))
    sys.exit(0)
if a[:2] in (["run", "cancel"], ["run", "rerun"]): sys.exit(0)
if a[0] == "api":
    q = opt(["-q", "--jq"])
    path = next(x for x in a[1:] if not x.startswith("-") and x != q)
    path = re.sub(r"^repos/[^/]+/[^/]+/", "", path)
    m = re.fullmatch(r"actions/runs/(\d+)", path)
    if m:
        r = next((r for r in runs if r["databaseId"] == int(m.group(1))), None)
        if r is None: sys.exit(1)
        emit({"id": r["databaseId"], "status": r["status"], "conclusion": r["conclusion"], "run_attempt": r.get("attempt", 1)}, q); sys.exit(0)
    m = re.fullmatch(r"actions/runs/(\d+)/attempts/(\d+)/jobs", path)
    if m: emit(load(f"jobs-{m.group(1)}-a{m.group(2)}.json"), q); sys.exit(0)
    m = re.fullmatch(r"actions/runs/(\d+)/jobs", path)
    if m: emit(load(f"jobs-{m.group(1)}.json", {"jobs": []}), q); sys.exit(0)
    m = re.fullmatch(r"actions/runs/(\d+)/artifacts", path)
    if m: emit(load(f"artifacts-{m.group(1)}.json", {"artifacts": []}), q); sys.exit(0)
    m = re.fullmatch(r"actions/artifacts/(\d+)/zip", path)
    if m:
        import io, zipfile
        f = f"{FX}/attest-{m.group(1)}.json"
        if not os.path.exists(f): sys.exit(1)
        b = io.BytesIO(); z = zipfile.ZipFile(b, "w"); z.write(f, "review-attestation.json"); z.close()
        sys.stdout.buffer.write(b.getvalue()); sys.exit(0)
    m = re.fullmatch(r"actions/jobs/(\d+)/logs", path)
    if m:
        f = f"{FX}/log-{m.group(1)}.txt"
        if not os.path.exists(f): sys.exit(1)
        sys.stdout.write(open(f).read()); sys.exit(0)
    m = re.match(r"actions/workflows/([^/?]+)/runs\??(.*)", path)
    if m:
        qs = dict(kv.split("=", 1) for kv in m.group(2).split("&") if "=" in kv)
        rs = [r for r in runs if r["path"].endswith("/" + m.group(1)) and r["event"] == "workflow_run"] if qs.get("page", "1") == "1" else []
        emit({"workflow_runs": [{"id": r["databaseId"], "display_title": r["displayTitle"], "event": r["event"], "run_attempt": r.get("attempt", 1),
              "head_branch": r["headBranch"], "path": r["path"], "status": r["status"], "conclusion": r["conclusion"]} for r in rs]}, q)
        sys.exit(0)
sys.exit(1)
PY
# T3: thread start → a new thread (its task kept), show → its state ($FX/state-<id>, default running), send → recorded
cat > "$T/bin/t3" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "thread start")
    n=$(( $(ls "$FX"/task-* 2>/dev/null | wc -l) + 1 )); id=$(printf 'mcp:aaaaaaaa-0000-4000-8000-%012d' "$n")
    { echo "title: $6"; echo "args: $*"; cat; } > "$FX/task-$n"; echo "start $id $*" >> "$FX/t3"; echo "Started thread $id" ;;
  "thread show") echo "$3 $(cat "$FX/state-${3#mcp:}" 2>/dev/null || echo running)" ;;
  "thread send") m=$(cat); echo "send $3" >> "$FX/t3"; printf '%s\n' "$m" > "$FX/sent-$(date +%s%N)"; echo ok ;;
  *) echo "t3 $*" >> "$FX/t3" ;;
esac
SH
cat > "$T/bin/t3mcp" <<'SH'
#!/usr/bin/env bash
echo "mcp $1" >> "$FX/t3"; exit 1
SH
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" FAKEGH=$T/bin/fakegh.py T3_MCP=$T/bin/t3mcp
TH=mcp:11111111-1111-1111-1111-111111111111 SUP=mcp:22222222-2222-2222-2222-222222222222
NOWISO=$(date -u -d '+1 min' +%FT%TZ)   # the verdict of a rerun completes after the earlier attempt's receipts

setup() { # setup <name>: a fresh repository, fake API and state
  local n=$1
  X=$T/$n; FX=$X/fx; mkdir -p "$FX" "$X/wt"; export FX
  git init -q --bare -b main "$X/remote.git"; git init -q -b main "$X/w"; git -C "$X/w" remote add origin "$X/remote.git"
  RUNS=(); RID=$((RANDOM % 1000 * 1000 + 100000))
  export REPO=o/r SRC=$X/src STATE=$X/state GH_TOKEN=x T3_PROJECT=p SUPERVISOR_THREAD=$SUP DISPATCH_THREAD=mcp:33333333-3333-3333-3333-333333333333 \
         MAIN_BRANCH=main FIXER_WT_ROOT=$X/wt WAKE_URL=http://127.0.0.1:9 FIXER_ENDED_GRACE_MIN=0 DEV_ORPHAN_GRACE_SEC=0
  mkdir -p "$STATE"
}
g() { git -C "$X/w" -c user.name=t -c user.email=t@t "$@"; }
c() { echo "$1 $RANDOM" >> "$X/w/f-$1.ts"; g add -A; g commit -q -m "$1" -m "${2:+$2
}Loop: adhoc/test
Thread: $TH
Verify:
- [x] t"; g rev-parse HEAD; }
push() { g push -q -f origin "$@"; }
clone() { rm -rf "$SRC"; git clone -q "$X/remote.git" "$SRC"; }
listing() { # listing <id> <title> <status> <conclusion> [<attempts>] [<updatedAt>]
  RUNS+=("$(jq -nc --argjson id "$1" --arg t "$2" --arg st "$3" --arg c "$4" --argjson at "${5:-1}" --arg up "${6:-2026-11-17T00:00:00Z}" \
    '{databaseId: $id, displayTitle: $t, path: ".github/workflows/review.yml", workflowName: "Review", event: "workflow_run",
      headBranch: "main", headSha: "x", status: $st, conclusion: (if $c == "null" then null else $c end), attempt: $at,
      createdAt: "2026-11-17T00:00:00Z", updatedAt: $up, number: $id, name: "x"}')")
  (IFS=,; echo "[${RUNS[*]}]") | jq 'sort_by(-.databaseId)' > "$FX/runs.json"
}
jobs() { # jobs <id> <attempt> <latest attempt> <kind: pass|blocked|gate|fixes> [<completed_at>]
  local f="$FX/jobs-$1.json" jid=$(( $1 * 10 + $2 )) st tc rc
  [ "$2" = "$3" ] || f="$FX/jobs-$1-a$2.json"
  case "$4" in pass) st=success rc=success ;; blocked) st=failure rc=failure ;; gate) st=skipped rc=failure ;; fixes) st=skipped rc=success ;; esac
  tc=success; [ "$4" = gate ] && tc=cancelled
  jq -nc --argjson k "$2" --argjson jid "$jid" --arg st "$st" --arg rc "$rc" --arg tc "$tc" --arg at "${5:-2026-11-17T00:00:00Z}" \
    '{jobs: [{name: "sheepdog / tests", id: ($jid + 5), run_attempt: $k, status: "completed", conclusion: $tc, steps: []},
             {name: "sheepdog / review", id: $jid, run_attempt: $k, status: "completed", conclusion: $rc, completed_at: $at,
              steps: [{name: "Review (blocking; x)", conclusion: $st}]}]}' > "$f"
  case "$4" in
    blocked) printf '%s\n' "2026-11-17T00:00:00Z review-gate: reviewing a..b" "2026-11-17T00:00:00Z review-gate: FINDING #1 route=fixer commit=- — x" \
               "2026-11-17T00:00:00Z review-gate: BLOCKED #1 regression [should]: run $1 attempt $2 drops rows" "2026-11-17T00:00:00Z evidence: f-x.ts:1 drops it" ;;
    gate) printf '%s\n' "2026-11-17T00:00:00Z [gates 00:00:00] ERROR: commit ${GATE_SHA:-abc} missing trailer(s):  Verify: (Verify: is a bare line followed by '- [x] …' items)" ;;
    *) printf '%s\n' "2026-11-17T00:00:00Z review-gate: reviewing a..b" "2026-11-17T00:00:00Z review-gate: PASS" ;;
  esac > "$FX/log-$jid.txt"
}
attest() { # attest <id> <head> <base> [<kind>]: the run's legacy attestation (one attempt)
  jq -nc --arg h "$2" --arg b "$3" --arg k "${4:-review}" '{head: $h, base: $b, kind: $k}' > "$FX/attest-$1.json"
  echo "{\"artifacts\":[{\"name\":\"review-attestation\",\"id\":$1,\"expired\":false}]}" > "$FX/artifacts-$1.json"
}
run1() { # run1 <head> <kind> [<base> [<run conclusion>]] → RUN: a completed single-attempt review run of <head>
  RID=$((RID + 1)); RUN=$RID
  local c=success; [ "$2" = blocked ] && c=failure; c=${4:-$c}
  listing "$RUN" "review $1" completed "$c"; jobs "$RUN" 1 1 "$2"
  if [ -n "${3:-}" ]; then attest "$RUN" "$1" "$3" "$([ "$2" = fixes ] && echo tests-only-fix || echo review)"; fi
}
dispatch() { bash "$D" > "$X/out" 2>&1 || { cat "$X/out" "$STATE/dispatch.log" >&2; fail "$1: the dispatcher exited non-zero"; }; }
woken() { grep -c '^start ' "$FX/t3" 2>/dev/null || true; }
task_for() { { grep -l "^title: .*${1:0:9}" "$FX"/task-* 2>/dev/null || true; } | tail -1; }

# (a) X blocked (its run concluded cancelled: the dispatcher cancelled its tests), then main's hotfix merged into dev — the
# merge round passed. Before: nobody looked below the head.
setup a
P=$(c p); push main
g checkout -q -b dev; XA=$(c xa)
g checkout -q main; H=$(c h "Hotfix: urgent"); push main
g checkout -q dev; g merge -q --no-ff main -m "merge main into dev" -m "Loop: review-dispatch
Thread: mcp:33333333-3333-3333-3333-333333333333
Verify:
- [x] t"; MM=$(g rev-parse HEAD); push dev
clone
run1 "$XA" blocked "$P" cancelled; run1 "$MM" pass "$XA"
dispatch a
f=$(task_for "$XA"); [ -n "$f" ] || fail "(a) no fixer for the blocked commit below the merge head: $(cat "$STATE/dispatch.log")"
grep -q "HEAD:refs/heads/devfix/${XA:0:12}" "$f" || fail "(a) the oldest blocked commit's fixer is not on the devfix fast path: $(cat "$f")"
grep -q 'run [0-9]* attempt 1 drops rows' "$f" || fail "(a) the fixer did not get the blocked verdict's findings"
grep -q "blocked commits without their Review-Fix-Of: repair (oldest first): ${XA:0:9}" "$STATE/dispatch.log" || fail "(a) walk not logged"
n=$(woken); dispatch a2; [ "$(woken)" = "$n" ] || fail "(a) a second run woke another fixer"
echo 'ok - (a) a block below a merge head gets its fixer'

# (b) X blocked and deferred while Y's fixer had the slot (7caac614a behind 856137bb9); Y is repaired on dev now. X is queued
# while Y's fixer thread still runs (one fixer per repository), and gets its fixer once that thread ended.
setup b
P=$(c p); push main; g checkout -q -b dev
XB=$(c xb); YB=$(c yb); RY=$(c ry "Review-Fix-Of: $YB"); push dev
clone
run1 "$XB" blocked "$P" cancelled; run1 "$YB" blocked "$XB"
mkdir -p "$STATE/sent"; echo "$YB" > "$STATE/dev-fixer.active"; echo "mcp:bbbbbbbb-0000-4000-8000-000000000001" > "$STATE/sent/$YB.fixer-blocked"
touch "$STATE/sent/$XB.fixer-deferred"
dispatch b
grep -q "queued blocked ${XB:0:9}" "$STATE/dispatch.log" || fail "(b) while Y's fixer runs, X is not queued for the next fixer: $(cat "$STATE/dispatch.log")"
[ -z "$(task_for "$XB")" ] || fail "(b) a second fixer ran beside Y's"
echo interrupted > "$FX/state-bbbbbbbb-0000-4000-8000-000000000001"   # Y's fixer thread ended (11-16 11:33Z)
dispatch b2
f=$(task_for "$XB"); [ -n "$f" ] || fail "(b) the commit that waited for the slot never got its fixer: $(cat "$STATE/dispatch.log")"
[ "$(cat "$STATE/dev-fixer.active")" = "$XB" ] || fail "(b) the slot did not move to the waiting commit"
[ -z "$(task_for "$YB")" ] || fail "(b) a fixer was woken for the repaired commit"
echo 'ok - (b) a block that waited for the fixer slot gets it once the holder is repaired'

# (c) B blocked, S blocked above it; B's repair RB is on dev ABOVE S; devfix/S (FS, green tests) cannot land on main.
setup c
P=$(c p); push main; g checkout -q -b dev
B=$(c b); S=$(c s); RB=$(c rb "Review-Fix-Of: $B"); push dev
g checkout -q -b fx "$S"; FS=$(c fs "Review-Fix-Of: $S
Hotfix: review fix of ${S:0:9}"); push "fx:refs/heads/devfix/${S:0:12}"; g checkout -q dev
clone
run1 "$B" blocked "$P"; run1 "$S" blocked "$B"; run1 "$FS" fixes "$S"
mkdir -p "$STATE/sent"; echo "$S" > "$STATE/dev-fixer.active"; echo "mcp:cccccccc-0000-4000-8000-000000000001" > "$STATE/sent/$S.fixer-blocked"
echo completed > "$FX/state-cccccccc-0000-4000-8000-000000000001"
dispatch c
git -C "$SRC" fetch -q --prune origin
git -C "$SRC" merge-base --is-ancestor "$FS" origin/dev || fail "(c) the unlandable devfix was not merged into dev: $(cat "$STATE/dispatch.log")"
! git -C "$SRC" rev-parse -q --verify "origin/devfix/${S:0:12}" >/dev/null || fail "(c) the devfix branch was kept"
grep -q "merged into dev as" "$STATE/dispatch.log" || fail "(c) not logged"
# re-check of 60d3f0b #1/#2 (data-loss): devfix/S moves (a fixer pushes FS2) between the dispatcher's merge into dev and its
# delete of the branch — the delete is leased on the merged head, so FS2 survives
setup c3
P=$(c p); push main; g checkout -q -b dev
B=$(c b); S=$(c s); RB=$(c rb "Review-Fix-Of: $B"); push dev
g checkout -q -b fx "$S"; FS=$(c fs "Review-Fix-Of: $S
Hotfix: review fix of ${S:0:9}"); push "fx:refs/heads/devfix/${S:0:12}"; FS2=$(c fs2 "Review-Fix-Of: $S
Hotfix: review fix of ${S:0:9}"); g checkout -q dev
clone
run1 "$B" blocked "$P"; run1 "$S" blocked "$B"; run1 "$FS" fixes "$S"
mkdir -p "$STATE/sent"; echo "$S" > "$STATE/dev-fixer.active"; echo "mcp:cccccccc-0000-4000-8000-000000000002" > "$STATE/sent/$S.fixer-blocked"
echo completed > "$FX/state-cccccccc-0000-4000-8000-000000000002"
REALGIT=$(command -v git); mkdir -p "$X/gitbin"
cat > "$X/gitbin/git" <<SH
#!/usr/bin/env bash
"$REALGIT" "\$@"; rc=\$?
# right after the dispatcher's push of its merge into dev: the fixer pushes FS2 onto devfix/S
if [ \$rc = 0 ] && [[ " \$* " == *" HEAD:refs/heads/dev "* ]] && [ ! -e "$X/advanced" ]; then
  touch "$X/advanced"; "$REALGIT" -C "$X/w" push -q -f origin "$FS2:refs/heads/devfix/${S:0:12}"
fi
exit \$rc
SH
chmod +x "$X/gitbin/git"
PATH="$X/gitbin:$PATH" dispatch c3
[ -e "$X/advanced" ] || fail "(60d3f0b #1/#2) setup: the dispatcher never pushed its merge into dev: $(cat "$STATE/dispatch.log")"
[ "$(git --git-dir="$X/remote.git" rev-parse -q --verify "refs/heads/devfix/${S:0:12}" || true)" = "$FS2" ] || fail "(60d3f0b #1/#2) the moved devfix branch was deleted: FS2 lost"
grep -q "not deleted — it moved past ${FS:0:9}" "$STATE/dispatch.log" || fail "(60d3f0b #1/#2) the kept branch is not logged"
echo 'ok - a devfix branch that moved after its merge into dev is kept (leased delete)'

# … and a fixer woken for a commit with an unrepaired block below it pushes to dev, not devfix/
setup c2
P=$(c p); push main; g checkout -q -b dev
B=$(c b); S=$(c s); push dev
clone
run1 "$B" blocked "$P"; run1 "$S" blocked "$B"
mkdir -p "$STATE/sent"; echo "$S" > "$STATE/dev-fixer.active"   # S claimed the slot first (an older dispatcher)
dispatch c2
f=$(task_for "$S"); [ -n "$f" ] || fail "(c) no fixer for S: $(cat "$STATE/dispatch.log")"
grep -q 'HEAD:refs/heads/dev ' "$f" && grep -q "below ${S:0:9} have no Review-Fix-Of: repair under ${S:0:9}" "$f" || fail "(c) S's fixer was not sent to dev although ${B:0:9} below is unrepaired: $(cat "$f")"
! grep -q "refs/heads/devfix/" "$f" || fail "(c) S's fixer was told to push a devfix that could never land"
echo 'ok - (c) an unlandable devfix goes to dev; a fix above an unrepaired block is pushed to dev'

# (d) + (e): Q's run 1 attempt 1 failed in the commit gates (no verdict), its rerun (attempt 2) BLOCKED.
setup e
P=$(c p); push main; g checkout -q -b dev; Q=$(c q); push dev
clone
RID=$((RID + 1)); QR=$RID
listing "$QR" "review $Q" completed failure 1; jobs "$QR" 1 1 gate
dispatch e1
f=$(task_for "$Q"); [ -n "$f" ] || fail "(d) no fixer for the gate failure: $(cat "$STATE/dispatch.log")"
grep -q "args: .*devfix-${Q:0:9}-gate" "$f" || fail "(d) the gate fixer is not keyed 'gate': $(head -2 "$f")"
grep -q 'HEAD:refs/heads/main' "$f" && grep -q 'Hotfix:' "$f" || fail "(d) the gate fixer is not told to put the record on main as a Hotfix"
[ ! -s "$STATE/dev-fixer.active" ] || fail "(d) the gate fixer took the dev fixer slot"
echo completed > "$FX/state-aaaaaaaa-0000-4000-8000-000000000001"
# the rerun: attempt 1 kept, attempt 2 BLOCKED
RUNS=(); listing "$QR" "review $Q" completed failure 2; mv "$FX/jobs-$QR.json" "$FX/jobs-$QR-a1.json"; jobs "$QR" 2 2 blocked "$NOWISO"
dispatch e2
f=$(task_for "$Q"); grep -q "args: .*devfix-${Q:0:9}-blocked" "$f" || fail "(e) the rerun's BLOCKED verdict got no fixer: $(cat "$STATE/dispatch.log")"
grep -q "run $QR attempt 2 drops rows" "$f" || fail "(e) the fixer did not get attempt 2's findings"
echo 'ok - (d) a gate failure: record on main, no dev slot; (e) the rerun verdict gets its own fixer'
# (e) from an older dispatcher's state: a "blocked" fixer + its notice for attempt 1, both older than the verdict
setup e3
P=$(c p); push main; g checkout -q -b dev; Q=$(c q); push dev
clone
RID=$((RID + 1)); QR=$RID
listing "$QR" "review $Q" completed failure 2; jobs "$QR" 1 2 gate; jobs "$QR" 2 2 blocked "$NOWISO"
mkdir -p "$STATE/sent"; echo "$Q" > "$STATE/dev-fixer.active"
echo "mcp:eeeeeeee-0000-4000-8000-000000000001" > "$STATE/sent/$Q.fixer-blocked"; echo completed > "$FX/state-eeeeeeee-0000-4000-8000-000000000001"
touch "$STATE/sent/$Q.fixfailed.0" "$STATE/sent/$Q.authors-spared"; printf 'gate\n' > "$STATE/sent/$Q.findings"
touch -d '-10 min' "$STATE/sent/$Q".*
mkdir -p "$STATE/fixer-gate/ended"; touch "$STATE/fixer-gate/ended/$Q.fixer-blocked"   # the repo gate cached the old fixer as ended
g branch -q "devfix-${Q:0:9}-blocked" "$Q"; git -C "$SRC" branch -q "devfix-${Q:0:9}-blocked" "$Q"   # the old fixer's branch
dispatch e3
f=$(task_for "$Q"); [ -n "$f" ] || fail "(e) legacy: the verdict after an older attempt's fixer got none: $(cat "$STATE/dispatch.log")"
grep -q "args: .*devfix-${Q:0:9}-blocked-r2" "$f" || fail "(e) legacy: the relaunch reused the old fixer's branch: $(head -2 "$f")"
ls "$STATE/sent/pre-verdict/" | grep -q "$Q.fixer-blocked.before-$QR-2" || fail "(e) legacy: the old receipts were not set aside"
[ ! -e "$STATE/fixer-gate/ended/$Q.fixer-blocked" ] || fail "(e) legacy: the gate still caches the replacement fixer's receipt as ended (re-check of 0fdd85b5a #1/#2)"
echo "ok - (e) an older dispatcher's pre-verdict fixer / notice no longer swallow the verdict; the gate sees the new fixer"

# orphan: X blocked, its fixer ended without a fix, and its fixfailed notice reached nobody (the supervisor's thread is archived)
# → the orphan notice goes to the supervisor, and — archived — to the CI owner (infra_alert), once
setup o
P=$(c p); push main; g checkout -q -b dev; XO=$(c xo); push dev
clone
run1 "$XO" blocked "$P"
mkdir -p "$STATE/sent"; echo "$XO" > "$STATE/dev-fixer.active"
echo "mcp:ffffffff-0000-4000-8000-000000000001" > "$STATE/sent/$XO.fixer-blocked"; echo completed > "$FX/state-ffffffff-0000-4000-8000-000000000001"
touch -d '-10 min' "$STATE/sent/$XO.fixer-blocked"
cp "$T/bin/t3" "$T/t3.normal"
cat > "$T/bin/t3" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "thread show") echo "$3 $(cat "$FX/state-${3#mcp:}" 2>/dev/null || echo running)" ;;
  "thread send") cat >/dev/null; echo "send $3" >> "$FX/t3"; [ "$3" = "$DISPATCH_THREAD" ] && { echo ok; exit 0; }; echo "Thread $3 is archived"; exit 1 ;;
  *) echo "t3 $*" >> "$FX/t3"; exit 1 ;;
esac
SH
dispatch o; dispatch o2
grep -q "nobody the dispatcher can wake owns it" "$STATE/dispatch.log" || fail "orphan: not reported: $(cat "$STATE/dispatch.log")"
[ "$(grep -c "^send $DISPATCH_THREAD" "$FX/t3")" = 1 ] || fail "orphan: the CI owner was not told exactly once (supervisor archived): $(cat "$FX/t3")"
[ "$(grep -c "nobody the dispatcher can wake owns it" "$STATE/dispatch.log")" = 1 ] || fail "orphan: reported more than once"
echo 'ok - a blocked commit nobody can own reaches the supervisor (or the CI owner) once'
cp "$T/t3.normal" "$T/bin/t3"   # the normal T3 stub again

# re-check of 0fdd85b5a #4: a later unfinished run of the same commit does not hide its completed first verdict
# (a newer failed run — Y's, already repaired — is what the train scan's "newest failure" looks at, as on tralyx)
setup f
P=$(c p); push main; g checkout -q -b dev; XF=$(c xf); YF=$(c yf); RYF=$(c ryf "Review-Fix-Of: $YF"); push dev
clone
run1 "$XF" blocked "$P"; RID=$((RID + 1)); listing "$RID" "review $XF" in_progress null; run1 "$YF" blocked "$XF"
dispatch f
[ -n "$(task_for "$XF")" ] || fail "(#4) a later unfinished run hid the completed blocked verdict: $(cat "$STATE/dispatch.log")"
echo 'ok - a later unfinished run does not hide a completed blocked verdict'

# re-check of 0fdd85b5a #5: Q (now below the head) had a gate-failed attempt 1, kept as "no verdict"; its rerun BLOCKED is
# the same "completed failure" in the routing listing — the rerun's identity (updatedAt) must invalidate that
setup n
P=$(c p); push main; g checkout -q -b dev; Q=$(c q); Y=$(c y); RY=$(c ry "Review-Fix-Of: $Y"); push dev
clone
mkdir -p "$STATE/verdicts"; touch "$STATE/verdicts/.full"   # the complete listing was read recently: the routing view decides
RID=$((RID + 1)); QR=$RID
GATE_SHA=${Q:0:9} listing "$QR" "review $Q" completed failure 1 2026-11-17T01:00:00Z; GATE_SHA=${Q:0:9} jobs "$QR" 1 1 gate
run1 "$Y" blocked "$Q"; YRUN=$RUN   # newer, repaired: the train scan's "newest failure"
dispatch n1
[ -s "$STATE/verdicts/$Q.none" ] || fail "(#5) setup: no-verdict not cached: $(ls "$STATE/verdicts")"
RUNS=(); listing "$QR" "review $Q" completed failure 2 2026-11-17T02:00:00Z; listing "$YRUN" "review $Y" completed failure
mv "$FX/jobs-$QR.json" "$FX/jobs-$QR-a1.json"; jobs "$QR" 2 2 blocked "$NOWISO"
echo completed > "$FX/state-aaaaaaaa-0000-4000-8000-000000000001"   # the gate fixer of attempt 1 ended
dispatch n2
f=$(task_for "$Q"); [ -n "$f" ] && grep -q "args: .*devfix-${Q:0:9}-blocked" "$f" || fail "(#5) the cached no-verdict hid the rerun's BLOCKED verdict: $(cat "$STATE/dispatch.log")"
echo "ok - a rerun invalidates the cached no-verdict"

# re-check of 0fdd85b5a #3: the gate fixer ended — complete only with the failing commit's OWN valid record in the CONFIGURED dir
gate_case() { # gate_case <name> <how: unrelated|wrongdir|configured> → whether the "fix did not succeed" notice went out
  setup "$1"
  P=$(c p); push main; g checkout -q -b dev; Q=$(c q); push dev; g checkout -q main
  clone
  local gs=${Q:0:9}; [ "$2" != spaced ] || gs=${Q:0:5}   # core.abbrev=5: the gates print 5 hex (re-check of d837792 #3)
  RID=$((RID + 1)); GATE_SHA=$gs listing "$RID" "review $Q" completed failure; GATE_SHA=$gs jobs "$RID" 1 1 gate
  dispatch "$1-1"
  [ -n "$(task_for "$Q")" ] || fail "(#3) setup: no gate fixer"
  echo completed > "$FX/state-aaaaaaaa-0000-4000-8000-000000000001"
  rec() { mkdir -p "$X/w/$(dirname "$1")"; printf 'Commit: %s\nVerify:\n- [x] evidence\n' "$2" > "$X/w/$1"; }
  case "$2" in
    unrelated) rec "scripts/ci/commit-verification/$P.txt" "$P" ;;                       # another commit's record
    wrongdir) rec "scripts/ci/commit-verification/$Q.txt" "$Q"
              mkdir -p "$X/w/.github/workflows"; printf 'jobs:\n  r:\n    with:\n      verification-dir: custom-proof\n' > "$X/w/.github/workflows/review.yml" ;;
    spaced) rec "proof records/commit-verification/$Q.txt" "$Q"   # a quoted dir with a space (re-check of d837792 #1/#2)
              mkdir -p "$X/w/.github/workflows"; printf 'jobs:\n  r:\n    with:\n      verification-dir: "proof records/commit-verification"\n' > "$X/w/.github/workflows/review.yml" ;;
    configured) rec "custom-proof/$Q.txt" "$Q"
              mkdir -p "$X/w/.github/workflows"; printf 'jobs:\n  r:\n    with:\n      verification-dir: custom-proof\n' > "$X/w/.github/workflows/review.yml" ;;
  esac
  g add -A; g commit -q -m "record" -m "Hotfix: record
Loop: adhoc/test
Thread: $TH
Verify:
- [x] t"; push main
  dispatch "$1-2"
  grep -q "sent gatefailed" "$STATE/dispatch.log"
}
gate_case gu unrelated || fail "(#3) another commit's record counted as the repair: $(cat "$STATE/dispatch.log")"
gate_case gw wrongdir || fail "(#3) a record outside the configured verification-dir counted as the repair"
! gate_case gs spaced || fail "(#3) a valid record in a quoted verification-dir with a space (gates abbreviating to 5 hex) was not accepted: $(cat "$STATE/dispatch.log")"
! gate_case gc configured || fail "(#3) a valid record in the configured verification-dir was not accepted: $(cat "$STATE/dispatch.log")"
echo "ok - a gate fixer is done only when main holds the failing commit's own record in the configured directory"

# re-check of 60d3f0b #6: the verdict's REVIEW findings are kept, the trusted tests are read afresh — X's tests failed when
# its verdict was first read (X waited for the slot), its tests rerun passed before X's fixer was woken: no failure routed
setup t
P=$(c p); push main; g checkout -q -b dev; XT=$(c xt); YT=$(c yt); push dev
clone
run1 "$XT" blocked "$P"; XTR=$RUN
jq '.jobs[0].conclusion = "failure"' "$FX/jobs-$XTR.json" > "$FX/j.tmp" && mv "$FX/j.tmp" "$FX/jobs-$XTR.json"
mkdir -p "$STATE/sent"; echo "$YT" > "$STATE/dev-fixer.active"; echo "mcp:dddddddd-0000-4000-8000-000000000001" > "$STATE/sent/$YT.fixer-blocked"
dispatch t1
[ -z "$(task_for "$XT")" ] || fail "(60d3f0b #6) setup: X got a fixer beside Y's"
[ -s "$STATE/verdicts/$XT" ] || fail "(60d3f0b #6) setup: X's verdict not kept"
jq '.jobs[0].conclusion = "success"' "$FX/jobs-$XTR.json" > "$FX/j.tmp" && mv "$FX/j.tmp" "$FX/jobs-$XTR.json"   # the tests rerun passed
echo completed > "$FX/state-dddddddd-0000-4000-8000-000000000001"
dispatch t2
f=$(task_for "$XT"); [ -n "$f" ] || fail "(60d3f0b #6) X got no fixer: $(cat "$STATE/dispatch.log")"
grep -q "run $XTR attempt 1 drops rows" "$f" || fail "(60d3f0b #6) the kept review findings were lost"
! grep -q 'trusted tests job' "$f" || fail "(60d3f0b #6) a tests failure that passed on rerun was routed to the fixer"
echo 'ok - kept review findings, current trusted tests: a passed rerun is not routed as a failure'
