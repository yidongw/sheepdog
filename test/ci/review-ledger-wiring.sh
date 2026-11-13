#!/usr/bin/env bash
# The review ledger reaches the blocking review (ported from yidongw/vpn-sub scripts/ci/test-review-flow.sh part 2,
# which tested vpn-sub's own review.yml before it adopted sheepdog). Runs review.yml's three steps as the runner would
# (the YAML's own `run:` text and env), with a stub prior-findings.sh and a stub `node` that records the reviewer's
# arguments: the previous findings and the de-duplicated known-open findings are handed to the reviewer; without the
# dispatcher's list the reviewer still runs, with an empty known-open file. Needs python3 + PyYAML; no network.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
W=$T/wf; mkdir -p "$W"
python3 - "$ROOT/.github/workflows/review.yml" "$W" <<'PY'
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["review"]; w = sys.argv[2]
steps = [s for s in job["steps"] if s.get("name")]; names = [s["name"] for s in steps]
by = {s["name"]: s for s in steps}
rev = next(x for x in names if x.startswith("Review (blocking"))
order = [names.index(x) if x in names else -1 for x in ("Previous findings (review ledger)", "Known open findings", rev)]
open(w + "/order", "w").write(" ".join(map(str, order)) + "\n")
for key, name in (("prior", "Previous findings (review ledger)"), ("known", "Known open findings"), ("review", rev)):
    s = by[name]
    open(f"{w}/{key}.sh", "w").write(s["run"]); open(f"{w}/{key}.if", "w").write(str(s.get("if", "")))
    open(f"{w}/{key}.wd", "w").write(str(s.get("working-directory", "")))
PY
read -r ip ik ir < "$W/order"
[ "$ip" -ge 0 ] && [ "$ik" -ge 0 ] && [ "$ir" -gt "$ip" ] && [ "$ir" -gt "$ik" ] \
  || fail "ledger steps missing or after the review (previous findings $ip, known open $ik, review $ir)"
# The blocking step is skipped only on a tests-only fix round (review-passed.sh never counts that as a review), and the
# ledger steps run exactly when it does; no skip path inside the step.
for k in prior known review; do
  [ "$(cat "$W/$k.if")" = "steps.range.outputs.kind == 'review'" ] || fail "$k step condition is '$(cat "$W/$k.if")'"
done
grep -qE '(^|[;&|[:space:]])exit 0' "$W/review.sh" && fail "the blocking review step has an exit-0 path"

# the runner's layout: candidate/ (working directory of the review steps) next to .sheepdog/ (the pinned sheepdog)
WS=$T/ws; mkdir -p "$WS/candidate" "$WS/.sheepdog/scripts/ci" "$WS/.sheepdog/reviewer/src" "$T/rt" "$T/bin" "$T/state"
git init -q -b main "$WS/candidate"
git -C "$WS/candidate" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
BASE=$(git -C "$WS/candidate" rev-parse HEAD)
printf '#!/usr/bin/env bash\necho "== the review that blocked $1..$2 (GH_TOKEN ${GH_TOKEN:+set} REPO $REPO BRANCH $REVIEW_DEFAULT_BRANCH)"\n' > "$WS/.sheepdog/scripts/ci/prior-findings.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$RUNNER_TEMP/args"\nwhile [ $# -gt 0 ]; do case "$1" in --prior) cp "$2" "$RUNNER_TEMP/got-prior";; --known-open) cp "$2" "$RUNNER_TEMP/got-known";; esac; shift; done\n' > "$T/bin/node"
chmod +x "$T/bin/node"
step() { # step <key>: the step's run text, in its working directory, with the env review.yml gives it
  local wd; wd=$(cat "$W/$1.wd"); [ -n "$wd" ] && wd=$WS/$wd || wd=$WS
  (cd "$wd" && PATH="$T/bin:$PATH" RUNNER_TEMP=$T/rt REVIEW_BASE=$BASE GH_TOKEN=x REPO=o/r REVIEW_DEFAULT_BRANCH=main \
    OPEN_FINDINGS=$OPEN REVIEWER_ENV_FILE= bash -e -c "$(cat "$W/$1.sh")" 2>&1)
}
OPEN=$T/state/open-findings.log
printf '%s\n' 'review-gate: BLOCKED #1 regression [should]: finding one' 'noise' 'review-gate: BLOCKED #2 regression [should]: finding one' 'review-gate: BLOCKED missed-class [should]: finding two' > "$OPEN"
out=$(step prior; step known; step review) || true
grep -qx -- '--prior' "$T/rt/args" 2>/dev/null && grep -qx -- '--known-open' "$T/rt/args" && grep -qx -- "$BASE" "$T/rt/args" \
  || fail "the reviewer was not called with --base/--prior/--known-open: $(tr '\n' ' ' <<<"$out") args: $(tr '\n' ' ' < "$T/rt/args" 2>/dev/null)"
grep -q "the review that blocked $BASE..HEAD (GH_TOKEN set REPO o/r BRANCH main)" "$T/rt/got-prior" \
  || fail "previous findings did not reach the reviewer: $(cat "$T/rt/got-prior" 2>/dev/null)"
[ "$(cat "$T/rt/got-known")" = "$(printf '%s\n' 'regression [should]: finding one' 'missed-class [should]: finding two')" ] \
  || fail "known-open findings not de-duplicated / stripped: $(cat "$T/rt/got-known")"
rm -f "$OPEN" "$T/rt/args" "$T/rt/got-known"
out=$(step prior; step known; step review) || true
grep -qx -- '--known-open' "$T/rt/args" 2>/dev/null && [ -e "$T/rt/got-known" ] && [ ! -s "$T/rt/got-known" ] \
  || fail "without a dispatcher list the review did not run with an empty known-open file: $(tr '\n' ' ' <<<"$out")"
echo 'ok - previous findings and de-duplicated known-open findings reach the blocking review; no list = empty file, review still runs'
