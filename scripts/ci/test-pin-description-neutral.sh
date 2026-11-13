#!/usr/bin/env bash
set -euo pipefail
block=$(sed -n '/export function buildPinBumpBlock/,/^}/p' reviewer/src/reviewer.ts)
if grep -Eq 'regression|For a finding there, cite' <<<"$block"; then exit 1; fi
echo 'PASS: pin description contains no verdict or attribution directions'
