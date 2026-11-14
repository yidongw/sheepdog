#!/usr/bin/env bash
# Review of dev 973b53dd8 #1/#2 (deac3d650's test, kept): a later effective repair of the culprit commit alone is no proof
# that a finding was repaired. Only a repair that declares THAT finding (Fixes-Finding: / Review-Disputed: with its text)
# drops it — the full cases (texts, numbers across rounds, disputes, several repairs) are in review-dispatch-route.sh.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
# Isolate the production predicate (and its helpers) without starting the dispatcher or notifying authors.
eval "$(sed -n '/^finding_norm() {/,/^dev_blocked() {/p' scripts/ci/review-dispatch.sh | sed '$d')"
DEV=dev SRC=$(mktemp -d); trap 'rm -rf "$SRC"' EXIT; git -C "$SRC" init -q
# A later effective repair exists for the culprit (it declares nothing about these findings).
repair_effective() { echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
F=$'review-gate: BLOCKED #1 regression [should]: one\nreview-gate: BLOCKED #2 regression [should]: two\nreview-gate: BLOCKED #3 regression [should]: three'
if culprits_repaired reviewed-head $'1 author culprit thread\n2 author culprit thread\n3 author other thread' "$F"; then
  echo 'FAIL: commit-level repair suppressed findings without finding-level proof' >&2
  exit 1
fi
[[ -z "$repaired_nums" && "$open_nums" == '1 2 3' ]]
echo 'PASS: all findings remain open without finding-level proof'
