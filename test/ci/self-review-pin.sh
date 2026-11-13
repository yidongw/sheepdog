#!/usr/bin/env bash
# sheepdog reviews itself with the reusable workflow at the sha pinned in .github/workflows/self-review.yml
# (docs/self-review.md). That pinned snapshot — not the candidate — is what actually reviews sheepdog, so it must carry
# the protections the candidate's tests demand (review of ad09c0b50 #1/#2: the pin shipped the old range walker that
# hotfix-range-forgery.sh's 60-commit merged-branch cases reject; review of pikeway 1304fbfa1 #1/#2: a pin without the
# pin-bump step or the self-review.yml run reader).
#
# Every review-flow suite of THIS tree (test/ci/*.sh except the dispatcher's — they exercise review-dispatch.sh /
# review-notify.sh / gh-cache.sh, which run from the host's trusted main checkout, never from the pin — and except this file) is run
# against the pinned tree: the pinned snapshot's scripts/, .github/ and reviewer/, with this tree's test/ci/ on top.
# A suite the pin does not pass fails this test, unless test/ci/self-review-pin.pending names it for exactly this pin:
#     <suite file name> <the 40-char pin> <why: the protection that is on dev/main but not yet in the pin>
# — an explicit, reviewed admission that the pin lags behind (a new protection lands first, the pin bump follows). A
# pending line for any other sha fails: a pin bump re-runs every suite against the new pin.
# The pinned commit is read from this clone, or fetched by sha from the public repository (a shallow CI checkout).
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SELF=$(basename "$0")
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

pin=$(python3 - "$ROOT/.github/workflows/self-review.yml" <<'PY'
import re, sys, yaml
jobs = (yaml.safe_load(open(sys.argv[1])) or {}).get("jobs") or {}
uses = [j.get("uses") for j in jobs.values() if isinstance(j, dict) and j.get("uses")]
m = re.fullmatch(r"yidongw/sheepdog/\.github/workflows/review\.yml@([0-9a-f]{40})", uses[0]) if len(uses) == 1 else None
print(m.group(1) if m else "")
PY
)
[ -n "$pin" ] || fail "self-review.yml: exactly one job calling yidongw/sheepdog/.github/workflows/review.yml@<40-char sha>"

# pending lines: well-formed, for this pin only
pending=" "
while IFS= read -r line; do
  line=${line%%#*}; [ -n "${line// }" ] || continue
  read -r suite sha why <<<"$line"
  if ! [[ "$suite" =~ ^[A-Za-z0-9._-]+\.sh$ ]] || ! [ -f "$ROOT/test/ci/$suite" ]; then fail "self-review-pin.pending: no suite '$suite'"; fi
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "self-review-pin.pending: '$suite' needs the full pin sha"
  [ "$sha" = "$pin" ] || fail "self-review-pin.pending: '$suite' is pending for ${sha:0:9}, the pin is now ${pin:0:9} — re-run it against the new pin (drop the line)"
  [ -n "${why// }" ] || fail "self-review-pin.pending: '$suite' needs a reason"
  pending+="$suite "
done < <(cat "$ROOT/test/ci/self-review-pin.pending" 2>/dev/null || true)

# the pinned tree
SNAP=$T/snap; mkdir -p "$SNAP"
if git -C "$ROOT" cat-file -e "$pin^{commit}" 2>/dev/null; then
  git -C "$ROOT" archive "$pin" | tar -x -C "$SNAP"
else
  git init -q "$T/pin.git"
  git -C "$T/pin.git" fetch -q --depth 1 --no-tags "https://github.com/yidongw/sheepdog.git" "$pin" \
    || fail "the pinned commit $pin is neither in this clone nor fetchable from yidongw/sheepdog"
  [ "$(git -C "$T/pin.git" rev-parse FETCH_HEAD)" = "$pin" ] || fail "fetched something else than $pin"
  git -C "$T/pin.git" archive FETCH_HEAD | tar -x -C "$SNAP"
fi
rm -rf "$SNAP/test/ci"; mkdir -p "$SNAP/test"; cp -r "$ROOT/test/ci" "$SNAP/test/ci"

suites=()
for f in "$ROOT"/test/ci/*.sh; do
  s=$(basename "$f")
  [ "$s" = "$SELF" ] && continue
  grep -qE 'review-dispatch\.sh|review-notify\.sh|gh-cache\.sh' "$f" && continue   # the dispatcher's suites
  suites+=("$s")
done
[ "${#suites[@]}" -ge 10 ] || fail "only ${#suites[@]} review-flow suites found"

export SNAP T
printf '%s\n' "${suites[@]}" | xargs -P 4 -I{} bash -c \
  'if bash "$SNAP/test/ci/{}" > "$T/{}.out" 2>&1; then echo ok > "$T/{}.rc"; else echo fail > "$T/{}.rc"; fi'
bad=0
for s in "${suites[@]}"; do
  r=$(cat "$T/$s.rc" 2>/dev/null || echo fail)
  case "$r:$pending" in
    ok:*" $s "*) echo "FAIL: $s is pending for the pin ${pin:0:9} but the pin passes it — drop the pending line" >&2; bad=1 ;;
    ok:*) ;;
    fail:*" $s "*) echo "pending: $s (the pin ${pin:0:9} lacks it, self-review-pin.pending)" ;;
    *) echo "FAIL: the pinned sheepdog ${pin:0:9} fails $s:" >&2; { grep -E 'FAIL|fail' "$T/$s.out" || tail -5 "$T/$s.out"; } | head -20 | sed 's/^/     /' >&2 || true; bad=1 ;;
  esac
done
[ "$bad" = 0 ] || exit 1
np=$(wc -w <<<"$pending"); ex=""; [ "$np" -eq 0 ] || ex=" except $np pending (self-review-pin.pending)"
echo "self-review pin ${pin:0:9}: the pinned snapshot passes this tree's ${#suites[@]} review-flow suites$ex"
