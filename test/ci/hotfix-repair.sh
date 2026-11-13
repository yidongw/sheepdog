#!/usr/bin/env bash
# Main repairs are reviewed once each, the deploy gate still checks coverage, and the fixer / report plumbing behaves
# (ported from yidongw/tralyx test/hotfix-repair.test.ts, whose cases yidongw/tralyx e820bc85f cut when these scripts
# moved here; now against sheepdog's hotfix-review-base.sh, review-passed.sh, review-dispatch.sh and review-notify.sh).
# The GitHub API is unreachable for the range (base = the head's parent: no completed main review, no tag deployed).
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
CI=$(cd "$(dirname "$0")/../../scripts/ci" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
check() { local what=$1; shift; if "$@"; then echo "ok - $what"; else echo "FAIL - $what" >&2; fails=$((fails + 1)); fi; }
g() { git -c user.name=fixture -c user.email=fixture@example.com -c core.hooksPath=/dev/null "$@"; }
c() { echo x > "f-$RANDOM$RANDOM"; g add -A; g commit -qm "$1"; git rev-parse HEAD; }
base() { GITHUB_API_URL=http://127.0.0.1:9 REPO=o/r GH_TOKEN=x bash "$CI/hotfix-review-base.sh" 2>/dev/null; }
base_fails() { ! GITHUB_API_URL=http://127.0.0.1:9 REPO=o/r GH_TOKEN=x bash "$CI/hotfix-review-base.sh" >/dev/null 2>&1; }
in_range() { git rev-list "$(base)..HEAD" | grep -qx "$1"; }

# A. a repair is reviewed alone (owner 11-12: one hotfix review round); the deploy gate checks coverage
git init -q -b main "$T/a"; cd "$T/a"
P=$(c production); H=$(c $'hotfix\n\nHotfix: original')
check "A: the hotfix's range starts at production" test "$(base)" = "$P"
F=$(c "$(printf 'repair\n\nReview-Fix-Of: %s\nHotfix: repair' "$H")")
check "A: a repair is reviewed alone (base = the repaired hotfix)" test "$(base)" = "$H"
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<SH
#!/usr/bin/env bash
[ "\$1" = api ] || exit 1; p=\$2; q=""; [ "\${3:-}" = -q ] && q=\$4
case "\$p" in
  *workflows/review.yml/runs*page=1*) o='{"workflow_runs":[{"id":1,"path":".github/workflows/review.yml","display_title":"review $F","status":"completed","conclusion":"success","event":"workflow_run","head_branch":"main"}]}' ;;
  *workflows/review.yml/runs*) o='{"workflow_runs":[]}' ;;
  */jobs) o='{"jobs":[{"name":"sheepdog / tests","conclusion":"success"},{"name":"sheepdog / review","conclusion":"success","steps":[{"name":"Review (blocking)","conclusion":"success"}]}]}' ;;
  */artifacts) o='{"artifacts":[{"id":2,"name":"review-attestation","expired":false}]}' ;;
  */zip) exec cat "$T/a/attestation.zip" ;;
  *) exit 1 ;;
esac
if [ -n "\$q" ]; then jq -r "\$q" <<<"\$o"; else printf '%s\n' "\$o"; fi
SH
chmod +x "$T/bin/gh"
gate() { # gate <attested base> [<sha>]: review-passed.sh <sha> against deployed P
  printf '{"head":"%s","base":"%s"}' "$F" "$1" > "$T/review-attestation.json"
  (cd "$T" && python3 -m zipfile -c "$T/a/attestation.zip" review-attestation.json)
  PATH="$T/bin:$PATH" GH_TOKEN=x bash "$CI/review-passed.sh" "${2:-$F}" fixture/repo "$P" >/dev/null 2>&1
}
check "A: H..F coverage cannot deploy over P by the strict path" eval '! gate "$H"'
check "A: P..F coverage deploys over P" gate "$P"
for case in "scripts/ci/autodeploy.sh scripts/ci/autodeploy.sh" "test/guard.ts -" "src/entry.ts docs/entry.ts" "src/entry.ts src/entry.md"; do
  read -r from to <<<"$case"
  g checkout -q --detach "$P"; mkdir -p "$(dirname "$from")"; echo original > "$from"; g add "$from"; g commit -qm "deployed file"
  if [ "$to" = - ]; then g rm -q "$from"; elif [ "$to" = "$from" ]; then echo changed > "$from"; g add "$from"
  else mkdir -p "$(dirname "$to")"; g mv "$from" "$to"; fi
  gap=$(c "unreviewed gap")
  check "A: an unreviewed gap ($from → $to) needs coverage" eval '! gate "$P" "$gap"'
done
g checkout -q --detach "$F"
I=$(c "intervening main commit"); c "$(printf 'repair again\n\nReview-Fix-Of: %s\nHotfix: repair' "$F")" >/dev/null
check "A: a repair after an intervening commit is reviewed from that commit" test "$(base)" = "$I"
c "$(printf 'invalid repair\n\nReview-Fix-Of: %040d' 0 | tr 0 a)" >/dev/null
check "A: a Review-Fix-Of: naming no ancestor fails the range" base_fails

# B. interleaved repairs and a divergent repair merge, each reviewed once
git init -q -b main "$T/b"; cd "$T/b"
P=$(c production); H1=$(c "hotfix one"); H2=$(c "hotfix two")
R1=$(c "$(printf 'repair one\n\nReview-Fix-Of: %s' "$H1")"); R2=$(c "$(printf 'repair two\n\nReview-Fix-Of: %s' "$H2")")
check "B: interleaved repairs: the range is the last repair alone" test "$(base)" = "$R1"
g branch repaired; g checkout -qb divergent "$P"; ADV=$(c "main advances")
g merge --no-ff -qm "$(printf 'repair landing\n\nReview-Fix-Of: %s' "$H2")" repaired
check "B: a divergent repair landing is reviewed against its first parent" test "$(base)" = "$ADV"
check "B: …and its merged-in side is in the range" eval 'in_range "$H1" && in_range "$H2" && in_range "$R1" && in_range "$R2"'

# C. train merges carry their second-parent side; later repairs alone
git init -q -b main "$T/c"; cd "$T/c"
P=$(c production); H=$(c "blocked main hotfix"); g branch main-side
g checkout -qb dev-side "$P"; S=$(c "dev change"); c "$(printf 'repair\n\nReview-Fix-Of: %s' "$S")" >/dev/null
g checkout -q main-side; g merge --no-ff -qm "train merge" dev-side
check "C: a train merge's range is its first parent .. merge" test "$(base)" = "$H"
check "C: …which carries the dev side" in_range "$S"
g commit --amend -qm "$(printf 'train merge\n\nReview-Fix-Of: %s' "$S")"
check "C: a train merge carrying Review-Fix-Of: of its dev side, the same range" test "$(base)" = "$H"
M=$(git rev-parse HEAD); c "$(printf 'repair train\n\nReview-Fix-Of: %s' "$M")" >/dev/null
check "C: a later repair naming the train merge is reviewed alone" test "$(base)" = "$M"
g checkout -qb unrelated "$P"; U=$(c "unrelated change"); g checkout -q main-side
c "$(printf 'invalid repair\n\nReview-Fix-Of: %s' "$U")" >/dev/null
check "C: a Review-Fix-Of: naming a commit beside main fails the range" base_fails

# D. the main repair prompt: pushes to main, reports to the dispatch log, dependency rules; optional model settings
cd "$T"; FN=$(awk '/^wake_fixer\(\) \{/ {on=1} on {print} on && /^}/ {exit}' "$CI/review-dispatch.sh")
for settings in "" "FIXER_PROVIDER=claudeAgent" "FIXER_PROVIDER=codex FIXER_MODEL=chosen"; do
  rm -rf "$T/d"; mkdir -p "$T/d/sent"; cd "$T/d"
  out=$(bash -c "set -euo pipefail
unset FIXER_PROVIDER FIXER_MODEL
$settings
REVIEW_NOTIFY_HELPER='$CI/review-notify.sh'
STATE=\$PWD; SRC=\$PWD; DEV=dev; T3_PROJECT=project
log() { :; }
timeout() { shift; \"\$@\"; }
t3() { printf '%s\n' \"\$@\" > args; cat > prompt; }
fixer_gate_pass() { return 0; }
FIXER_GATE=\$PWD/gate; mkdir -p \"\$FIXER_GATE/queue\"; fixer_gate_holder=
$FN
wake_fixer $(printf 'a%.0s' $(seq 40)) hotfixfix title 'Push to main' main author" 2>&1) || true
  p=$(cat prompt 2>/dev/null || true); a=$(cat args 2>/dev/null || true)
  check "D[$settings]: wake_fixer ran quietly" test -z "$out"
  check "D[$settings]: a main repair prompt never sends the fix to dev" eval '! grep -qE "HEAD:dev|do not push to main|worktree on dev" <<<"$p"'
  check "D[$settings]: the report goes to the dispatch log" eval 'grep -qF "fixer-report log" <<<"$p" && ! grep -qF "fixer-report-<thread>" <<<"$p"'
  check "D[$settings]: dependency rules (lockfile, symlinked node_modules, shared cache)" eval 'grep -qF "package-lock.json and the dependency fields of" <<<"$p" && grep -qF "does not change the installed tree" <<<"$p" && grep -qF "SYMLINK it: ln -s" <<<"$p" && grep -qF "never npm install through" <<<"$p" && grep -qF "shared cache" <<<"$p" && ! grep -qF "rename it to node_modules only after the copy succeeds" <<<"$p"'
  check "D[$settings]: the fixer starts from origin/main" grep -qF origin/main <<<"$a"
  want_m=no; want_p=no; [[ "$settings" == *FIXER_MODEL* ]] && want_m=yes; [[ "$settings" == *FIXER_PROVIDER* ]] && want_p=yes
  got_m=no; got_p=no; grep -qx -- --model <<<"$a" && got_m=yes; grep -qx -- --provider <<<"$a" && got_p=yes
  check "D[$settings]: --model / --provider only when set" test "$got_m$got_p" = "$want_m$want_p"
done

# E. report delivery: a Discord thread through the wake relay, a bare T3 uuid retried as mcp:<uuid>
rm -rf "$T/e"; mkdir -p "$T/e"; cd "$T/e"
bash -c "set -euo pipefail
STATE=\$PWD; LOG=\$PWD/log; mkdir -p \"\$STATE/sent\"
log() { :; }
source '$CI/review-notify.sh'
timeout() { shift; \"\$@\"; }
t3() { echo \"\$3\" >> calls; cat >/dev/null; [[ \"\$3\" = mcp:* ]]; }
curl() { printf '%s\n' \"\$@\" > curl-args; echo '{\"ok\":true}'; }
notify sha discord 1548373437326557311 report
notify sha t3 db8d0e35-531f-4cd4-845e-c90a82cde7da report" >/dev/null 2>&1 || true
check "E: a bare T3 uuid is retried as mcp:<uuid>" test "$(tr '\n' ' ' < calls 2>/dev/null)" = "db8d0e35-531f-4cd4-845e-c90a82cde7da mcp:db8d0e35-531f-4cd4-845e-c90a82cde7da "
check "E: a Discord thread goes through the wake relay" grep -qF /tool/wake_thread curl-args

# F. a failed T3 transport: failure, and nothing recorded as sent (retryable)
rm -rf "$T/f"; mkdir -p "$T/f/bin"; cd "$T/f"; printf '#!/bin/sh\nexit 1\n' > bin/t3; chmod +x bin/t3
rc=0; STATE=$T/f PATH="$T/f/bin:$PATH" bash "$CI/review-notify.sh" sha report mcp:db8d0e35-531f-4cd4-845e-c90a82cde7da <<<"report" >/dev/null 2>&1 || rc=$?
check "F: a failed T3 transport returns failure" test "$rc" = 1
check "F: …and leaves the delivery retryable (nothing in sent/)" test -z "$(find "$T/f/sent" -type f 2>/dev/null)"

# G. the dispatcher never mutates fixer worktrees' dependency installations
check "G: no automatic node_modules reclaim in the dispatcher" eval '! grep -qF reclaim_fixer_node_modules "$CI/review-dispatch.sh" && ! grep -qF "rm -rf -- \"\$tmp\"" "$CI/review-dispatch.sh"'

[ "$fails" = 0 ] || { echo "$fails checks failed" >&2; exit 1; }
echo "all hotfix repair checks passed"
