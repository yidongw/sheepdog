#!/usr/bin/env bash
set -euo pipefail
source scripts/ci/gh-cache.sh
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
ghc_init "$d"
printf '[{"databaseId":7,"status":"completed","updatedAt":"2026-11-13T10:00:00Z"}]' > "$GHC_RUN/list.old"
printf '{"id":7,"status":"completed","updated_at":"2026-11-13T10:01:00Z"}' > "$GHC_RUN/api.record"
if [ "${1:-}" = record ]; then
  test "$(ghc_run_state 7)" = 'completed 2026-11-13T10:01:00Z'
  exit
fi
printf '{"workflow_runs":[{"id":7,"status":"in_progress","updated_at":"2026-11-13T10:02:00Z"}]}' > "$GHC_RUN/api.page"
if [ "${1:-}" = page ]; then
  test "$(ghc_run_state 7)" = 'in_progress 2026-11-13T10:02:00Z'
  exit
fi
mkdir "$d/bin"
printf '#!/bin/bash\nprintf '\''[{"databaseId":7}]'\''\n' > "$d/bin/gh"
chmod +x "$d/bin/gh"
export PATH="$d/bin:$PATH"
ghc_put() { return 1; }
test "$(gh run list --json databaseId -q '.[0].databaseId')" = 7
