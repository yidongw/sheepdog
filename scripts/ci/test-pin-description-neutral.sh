#!/usr/bin/env bash
set -euo pipefail
block=$(sed -n '/export function buildPinBumpBlock/,/^}/p' reviewer/src/reviewer.ts)
if grep -Eq 'regression|For a finding there, cite' <<<"$block"; then exit 1; fi
# the scope requirement stays (pikeway review 43567914887 #1/#2: without it a pin bump's own diff had no explicit duty
# to be reviewed under the same rules)
grep -q 'review it as part of the range, under the same rules' <<<"$block" || exit 1
echo 'PASS: pin description contains no verdict or attribution directions'
