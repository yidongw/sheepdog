#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export STATE=$T tsha=head trid=123
mkdir -p "$STATE/sent"
# Exercise the train's classification gate with missing evidence and then a
# restored attestation, including a negative marker left by an older dispatcher.
python3 - <<'PY' > "$T/gate"
s=open('scripts/ci/review-dispatch.sh').read()
a=s.index('      [ -n "$trid" ]', s.index('for tsha in '))
b=s.index('      rp_main=1', a)+len('      rp_main=1')
print(s[a:b])
PY
touch "$STATE/sent/$tsha.nomain-$trid"
dev_split_main() { main_only=$available; main_nums=""; }
findings() { :; }
available=0
for attempt in 1; do source "$T/gate"; done
available=1
rp_main=0
for attempt in 2; do source "$T/gate"; done
[ "$rp_main" = 1 ] || { echo 'FAIL: restored evidence excluded from train'; exit 1; }
echo 'PASS: restored evidence retried despite old negative marker'
