#!/usr/bin/env bash
# The dispatcher's shell tests can never reach the real T3 (11-13 03:48Z: a test section called the real wake_fixer and a real
# fixer thread was started). With test/ci/lib/no-real-t3.sh sourced, a section that calls the real wake_fixer / steer without
# its own stub must FAIL — and the real `t3` (here: a recorder placed after the guard on PATH) is never run.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
cd "$(dirname "$0")/../.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/real" "$T/state/sent"
printf '#!/usr/bin/env bash\necho "$*" >> %q\necho mcp:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n' "$T/reached" > "$T/real/t3"; chmod +x "$T/real/t3"
cat > "$T/child.sh" <<'CHILD'
set -euo pipefail
source test/ci/lib/no-real-t3.sh
export PATH="$PATH:$REAL"                       # the "real" t3 comes after the guard, as the installed one does
eval "$(sed -n '/^wake_fixer() {/,/^}/p' scripts/ci/review-dispatch.sh)"
STATE=$CSTATE LOG=$CSTATE/log T3_PROJECT=p DEV=dev REVIEW_NOTIFY_HELPER=scripts/ci/review-notify.sh FIXER_GATE=$CSTATE/gate
log() { echo "$*" >> "$LOG"; }; fixer_gate_pass() { return 0; }
case "$1" in
  cli) wake_fixer "$(printf 'e%.0s' $(seq 40))" blocked title task dev "" || true ;;
  mcp) wf_provider=claudeAgent wf_model=m wf_effort=high wake_fixer "$(printf 'f%.0s' $(seq 40))" blocked title task dev "" || true ;;
  steer) source scripts/ci/review-notify.sh; steer_thread mcp:11111111-1111-1111-1111-111111111111 hi || true ;;
esac
echo REACHED-END
CHILD
for how in cli mcp steer; do
  rc=0; out=$(REAL=$T/real CSTATE=$T/state bash "$T/child.sh" "$how" 2>&1) || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: $how: a test section reached T3 without a stub and still passed" >&2; exit 1; }
  grep -q 'FAIL: test reached the real T3' <<<"$out" || { echo "FAIL: $how: no loud failure: $out" >&2; exit 1; }
  if grep -q REACHED-END <<<"$out"; then echo "FAIL: $how: the test went on after reaching T3" >&2; exit 1; fi
  if [ -e "$T/reached" ]; then echo "FAIL: $how: the real t3 was run: $(cat "$T/reached")" >&2; exit 1; fi
done
# a guard appends to the test's stderr log, never truncates it (main review of 31bea9704 #1, data-loss)
for g in test/ci/lib/bin/t3 test/ci/lib/t3-real-blocked; do
  : > "$T/err.log"
  bash -c 'echo PREVIOUS-DIAGNOSTIC >&2; GUARD_PID=$$ "$1" x y; sleep 5' _ "$PWD/$g" 2>>"$T/err.log" || true
  grep -q PREVIOUS-DIAGNOSTIC "$T/err.log" || { echo "FAIL: $g erased earlier diagnostics: $(cat "$T/err.log")" >&2; exit 1; }
  grep -q 'FAIL: test reached the real T3' "$T/err.log" || { echo "FAIL: $g: no guard message in the log" >&2; exit 1; }
done
# every dispatcher shell test sources the guard
for f in test/ci/*.sh; do grep -q 'source "$(dirname "$0")/lib/no-real-t3.sh"' "$f" || { echo "FAIL: $f does not source lib/no-real-t3.sh" >&2; exit 1; }; done
echo 'no test reaches the real T3'
