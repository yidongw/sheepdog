#!/usr/bin/env bash
# The repair detector must agree with the real gates for YAML directory strings and Git's configurable abbreviations.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
eval "$(sed -n '/^dev_gate_record_pushed() {/,/^}/p; /^dev_gate_failed() {/,/^}/p' "$ROOT/scripts/ci/review-dispatch.sh")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MAIN=main DEV=dev
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
g() { git -C "$SRC" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.invalid "$@"; }
log() { :; }
wake_fixer() { :; }
fixer_ended() { echo completed; }
or_supervisor() { echo fixture; }
notify_threads() { notices=$((notices + 1)); }
trailers=$'Loop: test\nThread: mcp:00000000-0000-0000-0000-000000000000'
checked=$'Verify:\n- [x] fixture evidence'
check_notice() {
  local want=$1
  notices=0
  dev_gate_failed "$sha" "$findings" fixture fixture
  [ "$notices" = "$want" ] || fail "$name: expected $want failed-fixer notices, got $notices"
}
run_gates() {
  (cd "$SRC" && SHEEPDOG_VERIFICATION_DIR="$trusted/$directory" bash "$ROOT/scripts/ci/commit-gates.sh" "$base" "$sha")
}
check_case() { # <name> <YAML scalar (empty = omitted)> <decoded directory> <core.abbrev>
  local name=$1 scalar=$2 directory=$3 abbrev=$4 before=$failures base sha findings short rc trusted
  SRC=$T/$name/repo STATE=$T/$name/state trusted=$T/$name/trusted
  mkdir -p "$STATE/sent" "$trusted/$directory"
  git init -q -b main "$SRC"
  g config core.abbrev "$abbrev"
  mkdir -p "$SRC/.github/workflows"
  printf 'jobs:\n  review:\n    uses: owner/repo/.github/workflows/review.yml@main\n    with:\n      main-branch: main\n' > "$SRC/.github/workflows/review.yml"
  if [ -n "$scalar" ]; then printf '      verification-dir: %s\n' "$scalar" >> "$SRC/.github/workflows/review.yml"; fi
  g add .; g commit -q -m base -m "$trailers" -m "$checked"; base=$(g rev-parse HEAD)
  g checkout -q -b dev
  g commit -q --allow-empty -m 'published without verification' -m "$trailers"; sha=$(g rev-parse HEAD)
  short=$(g rev-parse --short "$sha")
  [ "${#short}" = "$abbrev" ] || { echo "fixture abbreviation collision" >&2; exit 1; }
  rc=0; findings=$(run_gates) || rc=$?
  [ "$rc" = 3 ] || { echo "fixture: gates should refuse missing Verify, got $rc: $findings" >&2; exit 1; }
  grep -qF "ERROR: commit $short missing trailer(s):  Verify:" <<<"$findings" || exit 1
  # The detector receives the same gate ERROR section the dispatcher extracts from the real log.
  findings=$(grep '^\[gates .*ERROR' <<<"$findings")
  g update-ref refs/remotes/origin/main main
  touch "$STATE/sent/$sha.fixer-gate"
  if dev_gate_record_pushed "$findings"; then fail "$name: missing record accepted"; fi
  check_notice 1

  # Publish the SHA-bound record on main, with a separate trusted checkout for the actual gate invocation.
  g checkout -q main
  mkdir -p "$SRC/$directory"
  printf 'Commit: %s\n%s\n' "$sha" "$checked" > "$SRC/$directory/$sha.txt"
  cp "$SRC/$directory/$sha.txt" "$trusted/$directory/$sha.txt"
  g add .; g commit -q -m 'trusted verification record' -m "$trailers" -m "$checked"
  g update-ref refs/remotes/origin/main main
  g checkout -q --detach "$sha"
  if ! run_gates > "$T/$name/gates.out"; then cat "$T/$name/gates.out" >&2; fail "$name: real gates rejected repaired commit"; fi
  if ! dev_gate_record_pushed "$findings"; then fail "$name: detector rejected the repair the real gates accept"; fi
  check_notice 0
  [ "$failures" != "$before" ] || echo "ok - $name: real gates and detector agree; no false failed-fixer notice"
}
mode=${1:-all}
case "$mode" in dirs|abbrev|all) ;; *) echo 'usage: gate-record.sh [dirs|abbrev|all]' >&2; exit 2 ;; esac
if [ "$mode" != abbrev ]; then
  check_case double '"proof records/commit-verification" # configured' 'proof records/commit-verification' 7
  check_case single "'proof records/commit-verification' # configured" 'proof records/commit-verification' 7
  check_case plain 'proof records/commit-verification # configured' 'proof records/commit-verification' 7
  check_case hash '"proof # records/commit-verification"' 'proof # records/commit-verification' 7
  check_case escaped '"proof\x20records/commit-verification"' 'proof records/commit-verification' 7
  check_case block $'|-\n        proof records/commit-verification' 'proof records/commit-verification' 7
  check_case default '' scripts/ci/commit-verification 7
fi
if [ "$mode" != dirs ]; then
  for abbrev in 4 5 6 7 40; do
    check_case "abbrev-$abbrev" '' scripts/ci/commit-verification "$abbrev"
  done
fi
[ "$failures" = 0 ] || { echo "$failures gate-record regression check(s) failed" >&2; exit 1; }
