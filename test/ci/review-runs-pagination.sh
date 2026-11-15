#!/usr/bin/env bash
# A full twentieth page is not a listing error or proof that no older recheck blocked.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
. "$(dirname "$0")/../../scripts/ci/test-review-fixtures.sh"
. "$CI/review-runs.sh"
review_api() {
  [ "${FAIL_PAGE:-}" != "${1##*&page=}" ] || return 1
  gh api "repos/o/r/$1"
}

P=$(c production); git update-ref refs/remotes/origin/main "$P"
S=$(c blocked)
F=$(c repair "Review-Fix-Of: $S")
run 1 "review $S" success failure "$P" '' blocked
run 2 "review $F" success skipped "$S" tests-only-fix
cp "$FX/runs.json" "$T/seed.json"
padding() {
  python3 - "$T/seed.json" "$FX/runs.json" "$1" <<'PY'
import json, sys
runs = json.load(open(sys.argv[1]))["workflow_runs"]
filler = dict(runs[0], display_title="review unrelated", conclusion="success")
runs += [dict(filler, id=10000 + i) for i in range(int(sys.argv[3]) - len(runs))]
with open(sys.argv[2], "w") as out:
    json.dump({"workflow_runs": runs}, out)
PY
}
for count in 1999 2000 2001; do
  padding "$count"
  review_runs_strict completed > "$T/list" || fail "$count completed runs treated as an unreadable listing"
  [ "$(wc -l < "$T/list")" -eq "$count" ] || fail "$count runs were truncated"
  RP "$F" o/r "$P" || fail "$count runs rejected a valid repair: $(cat "$T/err")"
  echo "ok: $count completed runs retain a valid tests-only approval"
done

# A recheck beyond the old cap must still invalidate the tests-only approval.
run 3 "recheck $F" success failure "$S" '' blocked
python3 - "$FX/runs.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["workflow_runs"].append(data["workflow_runs"].pop(0))
with open(sys.argv[1], "w") as out:
    json.dump(data, out)
PY
if RP "$F" o/r "$P"; then fail 'blocked recheck on page 21 was ignored'; fi
grep -q "main's re-check.*blocked" "$T/err" || fail "unexpected rejection: $(cat "$T/err")"
echo 'ok: blocked recheck on page 21 rejects approval'

# Even the empty page after exactly 2,000 runs must be read successfully.
padding 2000
. "$CI/review-coverage.sh"
for FAIL_PAGE in 1 20 21; do
  if review_runs_strict completed > "$T/list"; then fail "unreadable page $FAIL_PAGE accepted"; fi
  review_strict_runs=''
  review_recheck_blocked "$F" "$F" || fail "unreadable page $FAIL_PAGE did not block approval"
done
echo 'ok: read failures on pages 1, 20 and 21 remain errors'
