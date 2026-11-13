#!/usr/bin/env bash
# The review contract (CLAUDE.md "Review contract"): scripts/ci/test-review-contract.sh and the suites it runs
# (fake git history + fake GitHub, no network) — run here so CI (test/ci-shell-tests.test.ts) runs them.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
cd "$(dirname "$0")/../.."
REVIEW_CONTRACT_ONLY=1 bash scripts/ci/test-review-contract.sh
