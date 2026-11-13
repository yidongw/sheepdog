#!/usr/bin/env bash
# The review contract's supplemental suites (scripts/ci/test-review-*.sh, test-commit-gates.sh; no network): coverage /
# boundary regressions, the workflow's own range + gate steps on offline histories, first-result pipelines under
# pipefail, long-message trailer readers, trusted SHA-bound Verify records. test/ci/review-contract.sh runs the rest.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
cd "$(dirname "$0")/../.."
bash scripts/ci/test-review-regressions.sh
bash scripts/ci/test-review-workflow-ranges.sh --gates
bash scripts/ci/test-review-workflow-ranges.sh --summary
python3 scripts/ci/test-review-pipelines.py
bash scripts/ci/test-review-trailers.sh
bash scripts/ci/test-commit-gates.sh
