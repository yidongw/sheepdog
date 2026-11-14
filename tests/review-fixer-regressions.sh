#!/usr/bin/env bash
set -euo pipefail
source scripts/ci/review-main-culprits.sh
h=$(git rev-parse HEAD)
lines=$(mc_gate_lines "$h" <<LOG
review-gate: reviewing abcdef12..${h:0:8}
review-gate: no parseable verdict
review-gate: reviewing abcdef12..${h:0:8}
review-gate: FINDING #1 route=fixer commit=$h
review-gate: BLOCKED #1 replay
LOG
)
if [ "${1:-}" != cancelled-only ] && mc_classify "$lines" "$h" "$h"; then echo 'replayed marker cleared failure' >&2; exit 1; fi
# Execute the actual head-loop block with terminal tests and stubbed infrastructure routing.
block=$(sed -n '/    fall=\$f; f=\$dev_f/,/    since_f=/p' scripts/ci/review-dispatch.sh | sed '$d')
review_jobs() { echo '{"jobs":[{"name":"tests","conclusion":"cancelled"}]}'; }
dev_infra() { recovered=1; }
f=main; dev_f=''; rid=1; sha=$h; STATE=$(mktemp -d); DRY=1
trap 'rm -rf "$STATE"' EXIT
recovered=0
for attempt in 1; do eval "$block"; done
[ "$recovered" = 1 ] || { echo 'cancelled tests stranded' >&2; exit 1; }
echo 'regressions passed'
