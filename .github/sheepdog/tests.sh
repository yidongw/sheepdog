#!/usr/bin/env bash
# sheepdog's own trusted test list (main's copy; run by the `tests` job of self-review.yml in a checkout of the pushed
# commit on a GitHub-hosted runner): every shell suite, then the reviewer's typecheck and tests, and the check that the
# reviewer runs with no dependencies (node type stripping) — the same checks as ci.yml.
set -euo pipefail
git config --global user.name ci && git config --global user.email ci@example.invalid
echo "::group::shell suites"; bash test/run.sh; echo "::endgroup::"
echo "::group::reviewer: typecheck + tests"
(cd reviewer && npm ci --ignore-scripts --no-audit --no-fund && npx tsc --noEmit && npx vitest run)
echo "::endgroup::"
echo "::group::the reviewer runs with no dependencies"
(cd reviewer && rm -rf node_modules && rc=0 && { node src/review-gate.ts --help || rc=$?; } && test "$rc" -eq 2)
echo "::endgroup::"
