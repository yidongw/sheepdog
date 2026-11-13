#!/usr/bin/env bash
# The re-review of a fix gets the findings it claims to fix (11-13: the main reviews of 716197fce / 812474324 logged
# "previous findings unavailable" — review.yml's "Previous findings" step ran prior-findings.sh WITHOUT GH_TOKEN, every API
# call was a 404 on the private repo, and the script said nothing). Runs the script with exactly the env that step gives it.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
cd "$(dirname "$0")/../.."
ROOT=$PWD
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# the step's env, as review.yml defines it (secrets / context filled with test values)
stepenv=$(python3 - <<'PY'
import sys, yaml
w = yaml.safe_load(open(".github/workflows/review.yml"))
st = next((s for s in w["jobs"]["review"]["steps"] if s.get("name") == "Previous findings (review ledger)"), None)
if not st: sys.exit("no Previous findings step")
if "prior-findings.sh" not in st["run"]: sys.exit("step does not run prior-findings.sh")
for k, v in (st.get("env") or {}).items():
    print(k + "=" + str(v).replace("${{ secrets.GITHUB_TOKEN }}", "tok-123").replace("${{ github.repository }}", "o/r").replace("${{ inputs.main-branch }}", "main"))
PY
)
git init -q -b main "$T/src"; g() { git -C "$T/src" -c user.name=t -c user.email=t@t "$@"; }
g commit -q --allow-empty -m base; B=$(g rev-parse HEAD)
g commit -q --allow-empty -m blocked -m "Hotfix: x"; S=$(g rev-parse HEAD)
g commit -q --allow-empty -m fix -m "Review-Fix-Of: $S
Hotfix: fix"; F=$(g rev-parse HEAD)
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<CURL
#!/usr/bin/env bash
case "\$*" in *"Authorization: Bearer tok-123"*) ;; *) exit 22 ;; esac   # private repo: no token → 404
case "\$*" in
  *repos/o/r/actions/workflows/review.yml/runs*page=1*) echo '{"workflow_runs":[{"id":7,"display_title":"recheck $S","conclusion":"failure","event":"workflow_run","head_branch":"main","path":".github/workflows/review.yml"}]}' ;;
  *repos/o/r/actions/workflows/review.yml/runs*) echo '{"workflow_runs":[]}' ;;
  *repos/o/r/actions/runs/7/jobs*) echo '{"jobs":[{"name":"sheepdog / tests","id":9},{"name":"sheepdog / review","id":8}]}' ;;   # a called workflow's job names
  *repos/o/r/actions/jobs/8/logs*) printf '2026-11-13T00:00:00Z review-gate: BLOCKED #1 regression [should]: the old bug\n2026-11-13T00:00:00Z evidence: a.ts:1 x\n' ;;
  *) exit 22 ;;
esac
CURL
chmod +x "$T/bin/curl"
# shellcheck disable=SC2086 # one VAR=value per word
out=$(cd "$T/src" && env -i HOME="$HOME" PATH="$T/bin:$PATH" $stepenv bash "$ROOT/scripts/ci/prior-findings.sh" "$B" "$F" 2>"$T/err")
grep -q "^== the review that blocked $S (run 7):" <<<"$out" || { echo "FAIL: the step's env gets no previous findings ($(cat "$T/err"))" >&2; exit 1; }
grep -q 'the old bug' <<<"$out"
# and without a token it says so in the log instead of staying silent
(cd "$T/src" && env -i HOME="$HOME" PATH="$T/bin:$PATH" REPO=o/r bash "$ROOT/scripts/ci/prior-findings.sh" "$B" "$F" 2>"$T/err2" >/dev/null)
grep -q 'no GH_TOKEN' "$T/err2" || { echo "FAIL: a missing token is silent" >&2; exit 1; }
echo 'prior findings reach the re-review (review.yml passes the token)'
