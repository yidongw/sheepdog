#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir "$t/bin"
cat > "$t/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = run ]; then
  if [ "${FALLBACK:-}" = 1 ] && [[ "$*" == *workflowName* ]]; then exit 1; fi
  echo '[{"databaseId":1,"status":"completed","updatedAt":"new"}]'
else
  echo '{"jobs":[{"status":"completed","conclusion":"failure"}]}'
fi
GH
chmod +x "$t/bin/gh"
export PATH="$t/bin:$PATH"
source "$root/scripts/ci/gh-cache.sh"
for mode in fallback write; do
  ghc_init "$t/$mode"
  path=repos/a/b/actions/runs/1/jobs
  key=$(ghc_key "$path")
  echo '{"jobs":[{"status":"completed","conclusion":"success"}]}' > "$GHC_RUN/api.$key"
  echo 'completed old' > "$GHC_RUN/api.$key.st"
  cp "$GHC_RUN/api.$key" "$GHC_DIR/disk/$key"
  echo old > "$GHC_DIR/disk/$key.version"
  echo '[{"databaseId":1,"status":"completed","updatedAt":"old"}]' > "$GHC_RUN/list.old"
  if [ "$mode" = fallback ]; then export FALLBACK=1; else unset FALLBACK; ghc_put() { return 1; }; fi
  gh run list --json status >/dev/null
  result=$(gh api "$path")
  [ "$(jq -r '.jobs[0].conclusion' <<<"$result")" = failure ]
done
echo 'PASS: fallback and failed listing persistence invalidate both answer tiers'
