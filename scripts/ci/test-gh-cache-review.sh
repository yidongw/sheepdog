#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export FIXTURE=$t
mkdir "$t/bin"
cat > "$t/bin/gh" <<'GH'
#!/usr/bin/env bash
set -eu
if [ "$1 $2" = 'run list' ]; then
  [[ "$*" != *attempt* ]] || exit 1
  if [ -f "$FIXTURE/reject" ] && [[ "$*" == *displayTitle* ]]; then exit 1; fi
  jq -nc --arg v "$(cat "$FIXTURE/version")" '[{databaseId:1,status:"completed",updatedAt:$v}]'
elif [ "$1" = api ]; then
  echo call >> "$FIXTURE/calls"
  if [[ "$2" == */jobs ]]; then
    jq -nc --arg v "$(cat "$FIXTURE/version")" '{jobs:[{id:1,status:"completed",conclusion:$v}]}'
  else
    jq -nc --arg v "$(cat "$FIXTURE/version")" '{status:"completed",updated_at:$v}'
  fi
else exit 0
fi
GH
chmod +x "$t/bin/gh"
export PATH="$t/bin:$PATH"
source "$root/scripts/ci/gh-cache.sh"
ghc_init "$t/cache"
echo success > "$t/version"
gh run list --json databaseId >/dev/null
gh api repos/o/r/actions/runs/1/jobs >/dev/null
echo failure > "$t/version"
rm -f "$GHC_RUN"/list.*
gh run list --json databaseId >/dev/null
[ "$(gh api repos/o/r/actions/runs/1/jobs -q '.jobs[0].conclusion')" = failure ]
# Mutations must invalidate even a still-fresh API memo.
echo cancelled > "$t/version"
gh run rerun 1
[ "$(gh api repos/o/r/actions/runs/1/jobs -q '.jobs[0].conclusion')" = cancelled ]
# Older CLIs can reject the expanded field set but accept the original query.
touch "$t/reject"
rm -f "$GHC_RUN"/list.*
gh run list --json databaseId | jq -e '.[0].databaseId == 1' >/dev/null
echo 'PASS: refreshed listing, mutation invalidation, legacy fields and fallback'
