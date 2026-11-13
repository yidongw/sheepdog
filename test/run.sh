#!/usr/bin/env bash
# Run every shell suite (test/ci/*.sh: fake git histories + a fake GitHub API, no network). Exit non-zero if any fails.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
for t in test/ci/*.sh; do
  s=$(date +%s)
  if out=$(bash "$t" 2>&1); then echo "ok   $(( $(date +%s) - s ))s $t"
  else fails=$((fails + 1)); echo "FAIL $(( $(date +%s) - s ))s $t"; tail -20 <<<"$out" | sed 's/^/     /'; fi
done
[ "$fails" = 0 ] || { echo "$fails suite(s) failed"; exit 1; }
echo "all shell suites passed"
