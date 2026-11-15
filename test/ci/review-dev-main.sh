#!/usr/bin/env bash
# The default-branch rule of a DEV review (docs/contract.md, Findings): review.yml's "Reviewed range" step exports the
# default branch's sha as REVIEW_DEV_MAIN for a dev head only, and the blocking step passes it to review-gate.ts as
# --dev-main only when it is set — a re-check of the default branch never gets it (there such a finding blocks as always).
# The gate's conversion itself is tested in reviewer/test/review-gate.test.ts.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
cd "$(dirname "$0")/../.."
ROOT=$PWD
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

git init -q -b main "$T/src"
g() { git -C "$T/src" -c user.name=t -c user.email=t@t "$@"; }
c() { echo "$RANDOM" >> "$T/src/$1"; g add "$1"; g commit -q -m "$2" ${3:+-m "$3"}; g rev-parse HEAD; }
P=$(c f production)
g tag deployed "$P"
H=$(c hot "hotfix on main" "Hotfix: h")
g update-ref refs/remotes/origin/main "$H"
g checkout -q -b dev
D=$(c a "dev work")

# no review runs at all (a fake GitHub API: empty listings)
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'CURL'
#!/usr/bin/env bash
case "${@: -1}" in *workflows/*/runs*) echo '{"workflow_runs":[]}' ;; *) exit 22 ;; esac
CURL
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
case "$2" in *workflows/*/runs*) echo '{"workflow_runs":[]}' ;; *) exit 1 ;; esac
GH
chmod +x "$T/bin/curl" "$T/bin/gh"

mkdir -p "$T/.sheepdog" "$T/.trusted"; ln -s "$ROOT/scripts" "$T/.sheepdog/scripts"
git clone -q "$T/src" "$T/candidate"
python3 - "$T" <<'PY'
import sys, yaml
w = yaml.safe_load(open(".github/workflows/review.yml"))
steps = w["jobs"]["review"]["steps"]
step = lambda n: next(s for s in steps if (s.get("name") or "").startswith(n))
open(sys.argv[1] + "/range.sh", "w").write(step("Reviewed range")["run"])
gate = step("Review (blocking")["run"]
bad = []
if gate.count("--dev-main") != 1 or 'devmain=(--dev-main "$REVIEW_DEV_MAIN")' not in gate: bad.append("the blocking step passes --dev-main other than from REVIEW_DEV_MAIN")
if 'if [ -n "${REVIEW_DEV_MAIN:-}" ]; then devmain=' not in gate: bad.append("--dev-main is passed without REVIEW_DEV_MAIN set")
if '"${devmain[@]}"' not in gate.split("review-gate.ts", 1)[1]: bad.append("review-gate.ts is not given the --dev-main arguments")
for b in bad: print("FAIL: review.yml: " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY

range() { # range <branch> <sha> → the step's GITHUB_ENV
  git -C "$T/candidate" checkout -q --detach "$2"
  git -C "$T/candidate" update-ref refs/remotes/origin/main "$H"
  : > "$T/env"; : > "$T/out"
  (cd "$T/candidate" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r HEAD_BRANCH=$1 MAIN_BRANCH=main DEV_BRANCH=dev REVIEW_DEFAULT_BRANCH=main \
     GITHUB_ENV=$T/env GITHUB_OUTPUT=$T/out bash -e "$T/range.sh" > "$T/range.log" 2>&1) || fail "range step ($1): $(tail -5 "$T/range.log")"
}
range dev "$D"
grep -qx "REVIEW_DEV_MAIN=$H" "$T/env" || fail "a dev review does not export the default branch's sha: $(cat "$T/env")"
grep -qx "REVIEW_MAIN=$H" "$T/env" || fail "REVIEW_MAIN changed"
echo "ok - a dev review exports REVIEW_DEV_MAIN = the default branch's sha"
range main "$H"
grep -qx "REVIEW_DEV_MAIN=" "$T/env" || fail "a re-check of the default branch exports a dev main: $(cat "$T/env")"
echo "ok - a default-branch re-check exports no REVIEW_DEV_MAIN (its findings block as always)"
range feature "$D"
grep -qx "REVIEW_DEV_MAIN=" "$T/env" || fail "another branch exports a dev main"
echo "review-dev-main checks passed"
