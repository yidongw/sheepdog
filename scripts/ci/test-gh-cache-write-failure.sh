#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir "$t/bin"
cat > "$t/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' '[{"databaseId":1,"status":"queued"},{"databaseId":2,"status":"queued"}]'
GH
chmod +x "$t/bin/gh"
export PATH="$t/bin:$PATH"
source "$root/scripts/ci/gh-cache.sh"
ghc_init "$t/cache"
# Match the empty repo/workflow/event/branch filter key.
key=$(ghc_key '|||')
printf '%s\n' '[{"databaseId":1,"status":"completed"}]' > "$GHC_RUN/list.$key"
echo 100 > "$GHC_RUN/list.$key.n"
touch -d '5 minutes ago' "$GHC_RUN/list.$key"
ghc_put() { return 1; }
for state in expired absent; do
  if [ "$state" = absent ]; then rm -f "$GHC_RUN"/list.*; fi
  result=$(gh run list -L 1 --json status)
  jq -e '. == [{"status":"queued"}]' <<<"$result" >/dev/null
  [ "$(gh run list -L 1 --json status -q '.[0].status')" = queued ]
done
echo 'PASS: failed cache writes preserve fresh results, projection, limit and jq'
