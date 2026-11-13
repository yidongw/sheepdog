#!/usr/bin/env bash
# .github/sheepdog/tests.sh of an adopting repository: the trusted test list. sheepdog's `tests` job reads this file
# from the DEFAULT branch and runs it in a checkout of the pushed commit (the current directory), with a read-only
# token and no secrets. What the candidate's own config files make these commands do (package scripts, test config) is
# part of the diff the reviewer judges.
set -euo pipefail
npm ci --no-audit --no-fund
npx tsc --noEmit
npx vitest run
