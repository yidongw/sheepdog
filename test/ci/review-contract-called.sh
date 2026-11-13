#!/usr/bin/env bash
# The review contract again, with the job names GitHub gives a CALLED workflow: a repository runs sheepdog's review.yml
# through `uses:`, so its run's jobs are "<caller job> / tests" and "<caller job> / review". Every verdict reader
# (review-passed.sh, dev-review-base.sh, review-coverage.sh, prior-findings.sh) must accept both spellings.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
cd "$(dirname "$0")/../.."
JOB_PREFIX="sheepdog / " REVIEW_CONTRACT_ONLY=1 bash scripts/ci/test-review-contract.sh
JOB_PREFIX="sheepdog / " bash scripts/ci/test-review-regressions.sh
