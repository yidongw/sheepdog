#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
eval "$(sed -n '/^dev_blocked() {/,/^}/p' scripts/ci/review-dispatch.sh)"
DRY=1 DEV=dev STATE=/nonexistent
attribution() { echo '1 fixer culprit -'; }
dev_carries_fix() { dupfix_why=whole-repair; return 0; }
named_files() { :; }
culprits_repaired() { repaired_nums=1; open_nums=2; dupfix_why=repair; return 0; }
findings_subset() { echo remaining; }
att_of() { echo '2 fixer culprit -'; }
fix_budget_ok() { return 0; }
split_fixer() { echo 'FAIL: launched redundant fixer' >&2; exit 1; }
dev_blocked reviewed findings culprits url task
