#!/usr/bin/env bash
# The first commit above a cover base must be found without an early-closing pipe:
# even a short range can race, and a long range reliably SIGPIPEs git rev-list.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
BASE_SH=$PWD/scripts/ci/dev-review-base.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q -b main "$T/src"
g() { git -C "$T/src" -c user.name=t -c user.email=t@t "$@"; }
g commit -q --allow-empty -m root
root=$(g rev-parse HEAD)
echo hotfix > "$T/src/hotfix"; g add hotfix; g commit -q -m hotfix
main=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/main "$main"
g checkout -q -b dev "$root"
echo dev > "$T/src/dev"; g add dev; g commit -q -m dev
base=$(g rev-parse HEAD)
g merge -q --no-ff -m 'clean main merge' main
merge=$(g rev-parse HEAD)
# Fast-import creates ordinary descendant commits without thousands of worktree checkouts.
parent=$merge; epoch=$(date +%s)
for ((i=1; i<=3000; i++)); do
  message="history commit $i"
  printf 'commit refs/heads/long\nmark :%s\ncommitter t <t@t> %s +0000\ndata %s\n%s\nfrom %s\n\n' \
    "$i" "$((epoch + i))" "${#message}" "$message" "$parent"
  parent=:$i
done > "$T/history"
g fast-import --quiet < "$T/history"
head=$(g rev-parse long)
# fake API (the diff base needs none: approval checks main's side)
mkdir -p "$T/bin" "$T/api"
printf '{"head":"%s","base":"%s","kind":"review"}\n' "$main" "$root" > "$T/api/att.json"
python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.write(sys.argv[2],"review-attestation.json"); z.close()' "$T/api/att.zip" "$T/api/att.json"
cat > "$T/bin/curl" <<CURL
#!/usr/bin/env bash
u=\${@: -1}
case "\$u" in
  *workflows/review.yml/runs*page=1*) echo '{"workflow_runs":[{"id":7,"display_title":"recheck $main","status":"completed","conclusion":"success","event":"workflow_run","head_branch":"main","path":".github/workflows/review.yml"}]}' ;;
  *workflows/review.yml/runs*) echo '{"workflow_runs":[]}' ;;
  */actions/runs/7/jobs) echo '{"jobs":[{"name":"tests","conclusion":"success"},{"name":"review","id":8,"conclusion":"success","steps":[{"name":"Review (blocking; x)","conclusion":"success"}]}]}' ;;
  */actions/runs/7/artifacts) echo '{"artifacts":[{"name":"review-attestation","id":7}]}' ;;
  */actions/artifacts/7/zip) cat "$T/api/att.zip" ;;
  *) exit 22 ;;
esac
CURL
chmod +x "$T/bin/curl"
actual=$(cd "$T/src" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r bash "$BASE_SH" --diff "$base" "$head")
# owner 11-15: main's side is never in the dev diff — the (virtual) diff base carries it; the long history is dev's
if [ -n "$(g diff --name-only "$actual" "$head")" ] || [ "$(g rev-list --no-merges --count "$actual..$head")" != 3000 ] \
   || ! g merge-base --is-ancestor "$main" "$actual"; then
  echo 'FAIL: the diff base did not exclude the clean main merge (git rev-list / head SIGPIPE)' >&2
  exit 1
fi
echo 'long review range: diff base excludes the clean main merge under pipefail'
