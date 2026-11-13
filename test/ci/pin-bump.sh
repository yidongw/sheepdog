#!/usr/bin/env bash
# A caller's range that moves its sheepdog pin (docs/pin-bumps.md): runs review.yml's "sheepdog pin bump" step (its own
# run text and env) and the blocking review step (stub `node` recording the reviewer's arguments) on fake histories.
#   · a bump to a commit on sheepdog's main: the sheepdog diff old..new and its log are prepared, and the reviewer gets
#     --pin-repo/--pin-from/--pin-to/--pin-diff/--pin-log;
#   · a bump to a commit NOT on sheepdog's main (a branch, an unreviewed sha): the step fails (no review passes);
#   · no bump, the adoption commit (no pin at the base), a pin only in a comment: no pin arguments.
# Needs python3 + PyYAML; no network (sheepdog's "origin" is a local bare repository).
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
W=$T/wf; mkdir -p "$W"
python3 - "$ROOT/.github/workflows/review.yml" "$W" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["review"]["steps"]
for key, prefix in (("pin", "sheepdog pin bump"), ("review", "Review (blocking")):
    s = next(s for s in steps if s.get("name", "").startswith(prefix))
    open(f"{sys.argv[2]}/{key}.sh", "w").write(s["run"])
    open(f"{sys.argv[2]}/{key}.if", "w").write(str(s.get("if", "")))
PY
[ -z "$(cat "$W/pin.if")" ] || fail "the pin step must run on every range (also a tests-only fix round): if '$(cat "$W/pin.if")'"
g() { git -c user.name=t -c user.email=t@t "$@"; }
# sheepdog: origin (bare) with main A → B, and a side branch X (not on main)
git init -q --bare -b main "$T/sd.git"; git init -q -b main "$T/sd"; cd "$T/sd"
echo one > gate.sh; g add -A; g commit -qm "sheepdog A"; SA=$(git rev-parse HEAD)
echo "two (weaker)" > gate.sh; g commit -qam "sheepdog B: change the gate"; SB=$(git rev-parse HEAD)
git checkout -q -b side; echo side > gate.sh; g commit -qam "sheepdog X: unreviewed"; SX=$(git rev-parse HEAD)
git push -q "$T/sd.git" main side
WS=$T/ws; mkdir -p "$WS" "$T/rt" "$T/bin"
git clone -q "$T/sd.git" "$WS/.sheepdog"; git -C "$WS/.sheepdog" checkout -q --detach "$SA"
git -C "$WS/.sheepdog" update-ref -d refs/remotes/origin/main   # as actions/checkout leaves it: fetched by the step
# the caller: base pins A, head pins <new>
git init -q -b main "$WS/candidate"; cd "$WS/candidate"; mkdir -p .github/workflows
caller() { mkdir -p .github/workflows; printf 'name: Review\njobs:\n  sheepdog:\n    uses: yidongw/sheepdog/.github/workflows/review.yml@%s\n' "$1" > .github/workflows/review.yml; g add -A; g commit -qm "pin ${1:0:7}"; git rev-parse HEAD; }
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$RUNNER_TEMP/args"\n' > "$T/bin/node"; chmod +x "$T/bin/node"
step() { # step <key> <base>
  (cd "$WS/candidate" && PATH="$T/bin:$PATH" GITHUB_WORKSPACE=$WS GITHUB_ENV=$T/env RUNNER_TEMP=$T/rt REVIEW_BASE=$2 \
    KIND=${KIND:-review} SHEEPDOG_REPO=yidongw/sheepdog SHEEPDOG_REVIEW_WORKFLOW=review.yml REVIEWER_ENV_FILE= bash -e -c "$(cat "$W/$1.sh")" 2>&1)
}
run_both() { # run_both <base> → pin step rc in $prc; then the review step with the env the pin step wrote
  : > "$T/env"; rm -f "$T/rt/args"; prc=0; out=$(step pin "$1") || prc=$?
  [ "$prc" = 0 ] || return 0
  set -a; . "$T/env"; set +a
  step review "$1" >/dev/null || true
  unset PIN_FROM PIN_TO
}
B0=$(caller "$SA")
H=$(caller "$SB"); run_both "$B0"
[ "$prc" = 0 ] || fail "bump to a main commit failed: $out"
grep -qx -- "--pin-to" "$T/rt/args" && grep -qx "$SB" "$T/rt/args" && grep -qx "$SA" "$T/rt/args" && grep -qx yidongw/sheepdog "$T/rt/args" \
  || fail "the reviewer did not get the pin arguments: $(tr '\n' ' ' < "$T/rt/args")"
grep -q '^+two (weaker)' "$T/rt/sheepdog-pin/sheepdog-pin.diff" || fail "the sheepdog diff A..B is not prepared"
grep -q 'sheepdog B: change the gate' "$T/rt/sheepdog-pin/sheepdog-pin.log" || fail "the sheepdog log A..B is not prepared"
echo "ok - a bump to a commit on sheepdog's main: diff + log prepared, the reviewer gets --pin-*"
git reset -q --hard "$B0"; caller "$SX" >/dev/null; run_both "$B0"
[ "$prc" != 0 ] && grep -q "not on yidongw/sheepdog's main" <<<"$out" || fail "a bump to a commit off sheepdog's main was accepted: $out"
echo "ok - a bump to a commit that is not on sheepdog's main fails the review job"
git reset -q --hard "$H"; g commit -q --allow-empty -m other; run_both "$H"
[ "$prc" = 0 ] && ! grep -q -- "--pin" "$T/rt/args" || fail "a range without a bump passed pin arguments"
git rm -q .github/workflows/review.yml; g commit -qm "no caller yet"; NOPIN=$(git rev-parse HEAD); caller "$SB" >/dev/null; run_both "$NOPIN"
[ "$prc" = 0 ] && ! grep -q -- "--pin" "$T/rt/args" || fail "the adoption commit (no pin at the base) passed pin arguments"
printf '# was yidongw/sheepdog/.github/workflows/review.yml@%s\n' "$SA" >> .github/workflows/review.yml; g commit -qam comment; run_both "$(git rev-parse HEAD~1)"
[ "$prc" = 0 ] && ! grep -q -- "--pin" "$T/rt/args" || fail "a pin in a comment counted as a bump"
echo "ok - no bump / adoption / a comment: no pin arguments"
# review of 0f5d80c10 #1/#2: a valid QUOTED pin (or any other YAML spelling) is a pin; a pin replaced by something that is
# not one full sha fails closed; a caller that does not parse fails; a bump in a tests-only fix round fails
qcaller() { mkdir -p .github/workflows; printf 'name: Review\njobs:\n  sheepdog:\n    uses: "%s"\n' "$1" > .github/workflows/review.yml; g add -A; g commit -qm "quoted pin"; git rev-parse HEAD; }
QB=$(qcaller "yidongw/sheepdog/.github/workflows/review.yml@$SA"); qcaller "yidongw/sheepdog/.github/workflows/review.yml@$SB" >/dev/null; run_both "$QB"
[ "$prc" = 0 ] && grep -qx -- "--pin-to" "$T/rt/args" && grep -qx "$SB" "$T/rt/args" || fail "a quoted pin bump was not reviewed: $out"
git reset -q --hard "$QB"; qcaller "yidongw/sheepdog/.github/workflows/review.yml@$SX" >/dev/null; run_both "$QB"
[ "$prc" != 0 ] || fail "a quoted pin bump off sheepdog's main was accepted"
git reset -q --hard "$QB"; qcaller "yidongw/sheepdog/.github/workflows/review.yml@main" >/dev/null; run_both "$QB"
[ "$prc" != 0 ] && grep -q "expected one full sha" <<<"$out" || fail "a pin replaced by a branch name was accepted: $out"
git reset -q --hard "$QB"; printf 'jobs: [unclosed\n' > .github/workflows/review.yml; g commit -qam broken; run_both "$QB"
[ "$prc" != 0 ] || fail "a caller that does not parse was accepted"
git reset -q --hard "$QB"; qcaller "yidongw/sheepdog/.github/workflows/review.yml@$SB" >/dev/null; KIND=tests-only-fix run_both "$QB"
[ "$prc" != 0 ] && grep -q "tests-only fix round" <<<"$out" || fail "a pin bump in a tests-only fix round was accepted: $out"
echo "ok - quoted pins are pins; a non-sha replacement, an unparsable caller, a bump in a tests-only fix round: fail closed"
