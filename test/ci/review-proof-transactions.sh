#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
cd "$(dirname "$0")/../.."
. scripts/ci/review-coverage.sh
review_api() { printf '%s' '{"jobs":[{"name":"tests","conclusion":"failure"},{"name":"review","conclusion":"success","steps":[{"name":"Review (blocking)","conclusion":"skipped"}]}]}'; }
failed=0
if review_fix_round 1; then echo 'FAIL: failed tests accepted'; failed=1; fi
# A failed recursive proof must roll back links, preserving earlier successful work.
_review_link() { review_fix_links+='leaked '; return 1; }
review_fix_links='prior '
review_link 1 h a h 0 || true
if [ "$review_fix_links" != 'prior ' ]; then echo 'FAIL: rejected link leaked'; failed=1; fi
_review_covered() { review_fix_links+='sibling '; return 1; }
review_fix_links='prior '
review_covered b a h || true
if [ "$review_fix_links" != 'prior ' ]; then echo 'FAIL: failed sibling leaked'; failed=1; fi
exit "$failed"
