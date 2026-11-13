#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/review-machinery.sh"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
git init -q "$t"
git -C "$t" config user.email test@example.com
git -C "$t" config user.name test
mkdir -p "$t/.github/workflows"
echo 'pin: 1' > "$t/.github/workflows/check.yml"
git -C "$t" add .
git -C "$t" commit -qm base
base=$(git -C "$t" rev-parse HEAD)
git -C "$t" checkout -qb landing
echo 'pin: 2' > "$t/.github/workflows/check.yml"
git -C "$t" commit -qam upgrade
landing=$(git -C "$t" rev-parse HEAD)
git -C "$t" checkout -qb repair "$base"
echo repair > "$t/app"
git -C "$t" add .
git -C "$t" commit -qm repair
git -C "$t" merge -q -s ours landing -m rollback
files=$(review_machinery_files "$t" "$landing..HEAD")
[[ "$files" == '.github/workflows/check.yml' ]] || { echo 'FAIL: merge rollback escaped machinery guard' >&2; exit 1; }
echo 'PASS: merge rollback detected'
