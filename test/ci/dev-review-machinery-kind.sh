#!/usr/bin/env bash
# A dev range of only Review-Fix-Of: repairs is a tests-only round (the reviewer is skipped) — but never when it would
# land review machinery (review of dev c6dfe26bb #3): the landing guard (review-machinery.sh landing_machinery_files,
# used by the dispatcher and merge-branch.sh) refuses machinery on a tests-only approval, so a repair of reviewer/main.ts
# classified tests-only could neither be reviewed nor land. dev-review-base.sh --only-fixes (review.yml's "Reviewed
# range" classification and review-passed.sh's re-check of a tests-only round) uses the same definition:
#   · blocked review of X + a reviewer/main.ts (or .github/, scripts/ci/) repair → not only-fixes (kind review: full review);
#   · the same repair of a plain file → only-fixes (tests-only round), as before;
#   · a range whose own commits touch no machinery but which would still land machinery dev carries beyond main → full review;
#   · a full-review pass of the machinery repair is accepted by review-passed.sh as kind "review", which the landing guard lets land.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
ROOT=$PWD
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
git init -q -b main "$T/src"
g() { git -C "$T/src" -c user.name=t -c user.email=t@t "$@"; }
c() { mkdir -p "$(dirname "$T/src/$1")"; echo "$RANDOM" >> "$T/src/$1"; g add "$1"; g commit -q -m "$2" ${3:+-m "$3"}; g rev-parse HEAD; }
P=$(c f production); g update-ref refs/remotes/origin/main "$P"
g checkout -q -b dev
X=$(c a "dev work (its review blocked)")

# fake GitHub API: one trusted Review run per commit, read by curl (dev-review-base.sh) and gh (review-passed.sh)
mkdir -p "$T/bin" "$T/api"
run() { # run <id> <sha> <blocking step: success|failure>
  printf '{"id":%s,"path":".github/workflows/review.yml","display_title":"review %s","status":"completed","conclusion":"%s","event":"workflow_run","head_branch":"main"}\n' "$1" "$2" "$3" >> "$T/api/list"
  printf '{"jobs":[{"name":"sheepdog / tests","conclusion":"success","steps":[]},{"name":"sheepdog / review","id":%s,"conclusion":"%s","steps":[{"name":"Review (blocking)","conclusion":"%s"}]}]}\n' "$(($1 + 1000))" "$3" "$3" > "$T/api/$1.jobs"
  { echo "2026-11-13T00:00:00.0Z review-range: $P $2"; [ "$3" = failure ] && echo "2026-11-13T00:00:02.0Z review-gate: BLOCKED #1 regression [should]: x"; true; } > "$T/api/$(($1 + 1000)).log"
  printf '{"head":"%s","base":"%s","kind":"review"}\n' "$2" "$P" > "$T/api/review-attestation.json"
  python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.write(sys.argv[2],"review-attestation.json"); z.close()' "$T/api/$1.zip" "$T/api/review-attestation.json"
}
cat > "$T/bin/api" <<API
#!/usr/bin/env bash
u=\$1
case "\$u" in
  *workflows/review.yml/runs*) case "\$u" in *page=1*|*[!e]) jq -s '{workflow_runs: .}' "$T/api/list" ;; *) echo '{"workflow_runs":[]}' ;; esac ;;
  */actions/runs/*/jobs) id=\${u##*runs/}; cat "$T/api/\${id%%/*}.jobs" 2>/dev/null || exit 22 ;;
  */actions/jobs/*/logs) id=\${u%/logs}; cat "$T/api/\${id##*/}.log" 2>/dev/null || exit 22 ;;
  */actions/runs/*/artifacts) id=\${u##*runs/}; id=\${id%%/*}; echo "{\"artifacts\":[{\"name\":\"review-attestation\",\"id\":\$id}]}" ;;
  */actions/artifacts/*/zip) id=\${u%/zip}; cat "$T/api/\${id##*/}.zip" ;;
  *) exit 22 ;;
esac
API
printf '#!/usr/bin/env bash\nexec "%s/bin/api" "${@: -1}"\n' "$T" > "$T/bin/curl"
cat > "$T/bin/gh" <<GH
#!/usr/bin/env bash
[ "\$1" = api ] || exit 1
q=""; [ "\${3:-}" = -q ] && q=\$4
j=\$("$T/bin/api" "\$2") || exit 1
if [ -n "\$q" ]; then jq -r "\$q" <<<"\$j"; else printf '%s\n' "\$j"; fi
GH
chmod +x "$T/bin/"*
: > "$T/api/list"; run 21 "$X" failure
only_fixes() { (cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r bash "$ROOT/scripts/ci/dev-review-base.sh" --only-fixes "$1" "$2" 2>/dev/null); }

# control: a plain-file repair of the blocked X is a tests-only round
g checkout -q -b plain "$X"; FP=$(c a "fix of X" "Review-Fix-Of: $X")
only_fixes "$X" "$FP" || fail "a plain repair of a blocked review is no longer a tests-only round"
# the reviewer's fixture: the repair touches reviewer/main.ts → full review
for f in reviewer/main.ts .github/workflows/review.yml scripts/ci/review-passed.sh; do
  g checkout -q -B m "$X"; FM=$(c "$f" "fix of X in $f" "Review-Fix-Of: $X")
  if only_fixes "$X" "$FM"; then fail "a repair of $f was classified tests-only (the landing guard would refuse it: deadlock)"; fi
done
# own commits plain, but dev carries machinery beyond main (X2 changed scripts/ci/): landing it is machinery → full review
g checkout -q -B carry "$P"; X2=$(c scripts/ci/x.sh "dev machinery (its review blocked)"); run 22 "$X2" failure
FC=$(c a "fix of X2 (plain file)" "Review-Fix-Of: $X2")
if only_fixes "$X2" "$FC"; then fail "a plain repair that would land dev's machinery was classified tests-only"; fi

# after a passing (full) review the machinery repair is approved as kind "review" — the landing guard lands it
g checkout -q -B m "$X"; FM=$(c reviewer/main.ts "fix of X" "Review-Fix-Of: $X"); run 23 "$FM" success
(cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r REVIEW_KIND_OUT=$T/kind bash "$ROOT/scripts/ci/review-passed.sh" "$FM" >/dev/null 2>&1) \
  || fail "review-passed.sh rejected the fully reviewed machinery repair"
[ "$(cat "$T/kind")" = review ] || fail "the approval kind is '$(cat "$T/kind")', not review"
source "$ROOT/scripts/ci/review-machinery.sh"
[ -n "$(landing_machinery_files "$T/src" "$P" "$FM")" ] || fail "fixture: the repair lands machinery"
echo "ok - machinery repairs get the full review (classification = landing guard); plain repairs stay tests-only; a reviewed one lands"
