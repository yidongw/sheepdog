#!/usr/bin/env bash
# Test the classifier that the deployed workflow selects, with no pending waiver.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pin=$(python3 - "$ROOT/.github/workflows/self-review.yml" <<'PY'
import re, sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))['jobs']
uses = [j['uses'] for j in jobs.values() if 'uses' in j]
assert len(uses) == 1
print(re.fullmatch(r'yidongw/sheepdog/\.github/workflows/review\.yml@([0-9a-f]{40})', uses[0])[1])
PY
)
git -C "$ROOT" archive "$pin" | tar -x -C "$T"
rm -rf "$T/test/ci"; mkdir -p "$T/test"
cp -r "$ROOT/test/ci" "$T/test/ci"
bash "$T/test/ci/dev-review-machinery-kind.sh"
