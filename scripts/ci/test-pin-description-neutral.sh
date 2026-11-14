#!/usr/bin/env bash
set -euo pipefail
block=$(sed -n '/export function buildPinBumpBlock/,/^}/p' reviewer/src/reviewer.ts)
# no directions addressed to the reviewer (verdict, attribution, imperatives — review of dev c10ea344d #1)
if grep -Eiq 'regression|verdict|For a finding|cite|review it|\byou\b|\byour\b|\bmust\b|\bshould\b' <<<"$block"; then exit 1; fi
# the scope stays, stated as a fact about the range (pikeway review 43567914887 #1/#2: the pin bump's diff belongs to
# the code under review)
grep -q 'it is part of the code under review, held to the same rules' <<<"$block" || exit 1
echo 'PASS: pin description contains no verdict or attribution directions'
