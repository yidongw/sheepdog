#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Isolate the production predicate without starting the dispatcher or notifying authors.
eval "$(sed -n '/^culprits_repaired() {/,/^dev_blocked() {/p' scripts/ci/review-dispatch.sh | sed '$d')"
DEV=dev
# A later effective repair exists for the culprit, but only fixes its first defect.
# Even a matching finding number cannot identify a finding across review rounds.
repair_effective() { echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
if culprits_repaired reviewed-head $'1 author culprit thread\n2 author culprit thread\n3 author other thread'; then
  echo 'FAIL: commit-level repair suppressed findings without finding-level proof' >&2
  exit 1
fi
[[ -z "$repaired_nums" && "$open_nums" == '1 2 3' ]]
echo 'PASS: all findings remain open without finding-level proof'
