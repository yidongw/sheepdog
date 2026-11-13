#!/usr/bin/env bash
# A repair trailer can precede a long evidence block. Reading only through its match must not
# make git show die of SIGPIPE under pipefail and silently discard the effective repair.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
source scripts/ci/review-repair.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q -b main "$T/src"
g() { git -C "$T/src" -c user.name=t -c user.email=t@t "$@"; }
g commit -q --allow-empty -m 'blocked review'
blocked=$(g rev-parse HEAD)
{
  printf 'Repair the blocked review\n\nReview-Fix-Of: %s\n\nVerify:\n' "$blocked"
  for ((i=0; i<10000; i++)); do printf -- '- [x] evidence line %s: focused verification passed\n' "$i"; done
} > "$T/message"
g commit -q --allow-empty -F "$T/message"
repair=$(g rev-parse HEAD)
if ! (cd "$T/src" && repaired "$blocked" "$repair"); then
  echo 'FAIL: a valid repair with evidence after its trailer was ignored (git show / grep SIGPIPE)' >&2
  exit 1
fi
echo 'long repair message: effective repair recognized under pipefail'
