#!/usr/bin/env bash
# Review churn (owner 11-12): nits never reach the fixer as findings; a sha stops getting fixers after
# FIX_ROUNDS_MAX rounds along its Review-Fix-Of: chain (5 for security/funds/...) and the supervisor is woken once;
# a fix whose Verify: says NOT RUN or names no fails-before test is reported; conflict tasks decide CLOSE first;
# Review-Disputed: trailers and the previous findings reach the re-review prompt.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
# Any command that is not found — a dispatcher helper the test did not extract — fails the whole test at once, even
# inside an if / || condition (review of 02828988f #7: "culprits_repaired: command not found" printed, test exited 0).
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
ROOT=$PWD
script=$ROOT/scripts/ci/review-dispatch.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
STATE=$T/state SRC=$T/src MAIN=main DEV=dev REPO=o/r LOG=$T/state/dispatch.log
mkdir -p "$STATE/sent"
log() { echo "$*" >> "$LOG"; }
source scripts/ci/review-notify.sh
eval "$(sed -n '/^notify_best_effort() /p; /^findings_cap() {/,/^}/p; /^findings() {/,/^}/p; /^notes_of() {/,/^}/p; /^obsolete_rule() {/,/^}/p' "$script")"; for _f in notify_best_effort findings_cap findings notes_of obsolete_rule; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
SUPERVISOR_THREAD=import:claudeAgent:00000000-0000-4000-8000-000000000051
eval "$(sed -n '/^FIX_ROUNDS_MAX=/,/^# ── one fixer per repo/p' "$script")"
eval "$(sed -n '/^fixer_phrase() {/,/^}/p' "$script")"; for _f in fixer_phrase; do declare -F "$_f" >/dev/null || { echo "missing helper $_f (not extracted from the dispatcher)" >&2; exit 1; }; done
timeout() { shift; "$@"; }
# fake T3: counts the messages each thread got
t3() { [ "$1 $2" = "thread send" ] || return 1; cat > "$T/msg.$(ls "$T" | grep -c '^msg\.' || true)"; echo "$3" >> "$T/t3-sends"; }
sends() { grep -cx "$1" "$T/t3-sends" 2>/dev/null || true; }

# ── 1. severity: NIT lines are notes, not findings ──
cat > "$T/joblog" <<'L'
2026-11-12T00:00:00Z review-gate: BLOCKED #1 regression [blocker]: A breaks the main path
2026-11-12T00:00:00Z evidence: src/a.ts:1 returns null
2026-11-12T00:00:00Z review-gate: BLOCKED #2 ducktape [should, funds]: B
2026-11-12T00:00:00Z evidence: src/b.ts:2
2026-11-12T00:00:00Z review-gate: NIT (non-blocking): missed-class: rename helper (src/c.ts:3)
2026-11-12T00:00:00Z review-gate: NOTE (non-blocking): owner may want a quota check
L
gh() {
  case "$2" in
    */jobs) echo '{"jobs":[{"name":"review","id":7,"conclusion":"failure"},{"name":"tests","id":8,"conclusion":"success"}]}' ;;
    */jobs/7/logs) cat "$T/joblog" ;;
  esac
}
f=$(findings 1)
grep -q 'BLOCKED #1 regression \[blocker\]' <<<"$f"
grep -q 'BLOCKED #2 ducktape \[should, funds\]' <<<"$f"
if grep -q 'NIT\|rename helper' <<<"$f"; then echo "a nit reached the findings" >&2; exit 1; fi
n=$(notes_of 1)
grep -q 'nit: missed-class: rename helper' <<<"$n"
grep -q 'owner may want a quota check' <<<"$n"
echo "severity filtering ok"

# ── 2. round budget ──
git -C "$T" init -q -b main src
cm() { local file=$1; shift; local a=(); for m in "$@"; do a+=(-m "$m"); done
  mkdir -p "$SRC/$(dirname "$file")"; echo "$RANDOM" >> "$SRC/$file"; git -C "$SRC" add "$file"
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q "${a[@]}"; git -C "$SRC" rev-parse HEAD; }
base=$(cm README.md base); git -C "$SRC" update-ref refs/remotes/origin/main "$base"
S0=$(cm src/x.ts "feature")
c1=$(cm src/x.ts "fix 1" "Review-Fix-Of: $S0" "Loop: dev-fixer")
c2=$(cm src/x.ts "fix 2" "Review-Fix-Of: $c1" "Loop: dev-fixer")
c3=$(cm src/x.ts "fix 3" "Review-Fix-Of: $c2" "Loop: dev-fixer")
F="review-gate: BLOCKED #1 regression [blocker]: still wrong
evidence: src/x.ts:4"
test "$(fix_rounds "$S0" "$F")" = 0
test "$(fix_rounds "$c2" "$F")" = 2
test "$(fix_rounds "$c3" "$F")" = 3
fix_budget_ok "$c2" recheck "$F"                       # 2 rounds < 3: a fixer may go
if fix_budget_ok "$c3" recheck "$F"; then echo "4th fixer round allowed" >&2; exit 1; fi
test "$(sends import:claudeAgent:00000000-0000-4000-8000-000000000051)" -eq 0 2>/dev/null || test -z "$(sends import:claudeAgent:00000000-0000-4000-8000-000000000051)"   # owner 11-12: nobody woken when the rounds are spent
grep -q "fix budget spent: ${c3:0:9} (recheck) still blocked after 3 fixer rounds (max 3)" "$LOG"
grep -q "still wrong" "$STATE/open-findings.log"   # kept for whoever looks next
if fix_budget_ok "$c3" recheck "$F"; then echo "budget reopened" >&2; exit 1; fi
test "$(sends import:claudeAgent:00000000-0000-4000-8000-000000000051)" -eq 0 2>/dev/null || test -z "$(sends import:claudeAgent:00000000-0000-4000-8000-000000000051)"   # never woken
test "$(grep -c "still wrong" "$STATE/open-findings.log")" = 1   # listed once
test "$(grep -c "fix budget spent: ${c3:0:9}" "$LOG")" = 1                      # logged once
grep -q 'fix rounds are spent' <<<"$(fixer_phrase "$c3")"
# security / funds / data-loss / concurrency: 5 rounds
fix_budget_ok "$c3" blocked "review-gate: BLOCKED #1 regression [blocker, security]: token leak
evidence: src/x.ts:9"
# a fixer that already holds its receipt is not second-guessed
touch "$STATE/sent/$c3.fixer-testsfail"; fix_budget_ok "$c3" testsfail "$F"
# a plain dev head on top of fix 3 starts its own budget (owner 11-12: one review, one fix per commit)
h=$(cm src/y.ts "unrelated dev work")
test "$(fix_rounds "$h" "$F")" = 0   # owner 11-12: a commit's budget is its OWN chain — other fixes of the same file do not count
d1=$(cm src/x.ts "devfix of the head" "Review-Fix-Of: $h" "Loop: dev-fixer")
test "$(fix_rounds "$d1" "$F")" = 1
test "$(fix_rounds "$h" "evidence: src/other.ts:1")" = 0      # other files: a fresh problem, fresh budget
echo "round budget ok"

# ── 3. proof: NOT RUN / no fails-before line ──
git -C "$SRC" update-ref refs/remotes/origin/main "$d1"
p1=$(cm src/x.ts "proven" "Review-Fix-Of: $h" "Verify:
- [x] fails before / passes after: npx vitest run test/x.test.ts")
test -z "$(verify_gaps "$p1" "$h")"
p2=$(cm src/x.ts "not run" "Review-Fix-Of: $h" "Verify:
- [ ] NOT RUN: integration run blocked: no matching dependency installation")
g=$(verify_gaps "$p2" "$h")
grep -q "${p2:0:9} Verify says NOT RUN" <<<"$g"
p3=$(cm src/x.ts "ticked claims only" "Review-Fix-Of: $h" "Verify:
- [x] tests pass")
g=$(verify_gaps "$p3" "$h")
test "$(wc -l <<<"$g")" = 2
grep -q "${p3:0:9} Verify has no" <<<"$g"
echo "NOT RUN detection ok"

# ── 4. conflict tasks decide CLOSE vs MODERNIZE; the fixer task offers Review-Disputed: and demands proof ──
r=$(obsolete_rule devfix devfix/abc "$S0" "$base")
grep -q 'git push origin --delete devfix/abc' <<<"$r"; grep -q 'obsolete: ' <<<"$r"
grep -q "take origin/main's version of that hunk" <<<"$(obsolete_rule merge)"
wf=$(sed -n '/^wake_fixer() {/,/^}/p' "$script")
grep -q 'Review-Disputed: <finding #> <one-line evidence>' <<<"$wf"
grep -q -- '- \[x\] fails before / passes after: <exact command>' <<<"$wf"
grep -q -- '- \[ \] NOT RUN: <reason>' <<<"$wf"
echo "fixer task text ok"

# ── 5. Review-Disputed: + previous findings reach the re-review prompt ──
dsp=$(cm src/x.ts "fix with a dispute" "Review-Fix-Of: $c3" "Review-Disputed: #2 src/x.ts:4 already clamps; vitest run test/x.test.ts passes")
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<CURL
#!/usr/bin/env bash
case "\$*" in
  *workflows/review.yml/runs*) echo '{"workflow_runs":[{"id":41,"display_title":"recheck $c3","conclusion":"failure","event":"workflow_run","head_branch":"main","path":".github/workflows/review.yml"},{"id":40,"display_title":"review $c3","conclusion":"success","event":"workflow_run","head_branch":"main","path":".github/workflows/review.yml"}]}' ;;
  *runs/41/jobs*) echo '{"jobs":[{"name":"review","id":77}]}' ;;
  *jobs/77/logs*) printf '%s\n' '2026-11-12T00:00:00Z review-gate: BLOCKED #2 regression [should]: x overflows' '2026-11-12T00:00:00Z evidence: src/x.ts:4' '2026-11-12T00:00:00Z noise' ;;
  *) exit 22 ;;
esac
CURL
chmod +x "$T/bin/curl"
prior=$(cd "$SRC" && PATH=$T/bin:$PATH GH_TOKEN=x REPO=o/r bash "$ROOT/scripts/ci/prior-findings.sh" "$h" "$dsp")
grep -q "the review that blocked $c3 (run 41)" <<<"$prior"
grep -q 'x overflows' <<<"$prior"
if grep -q noise <<<"$prior"; then echo "log noise in prior findings" >&2; exit 1; fi
test -z "$(cd "$SRC" && PATH=$T/bin:$PATH bash "$ROOT/scripts/ci/prior-findings.sh" "$c3" "$h")"   # no fix in range: nothing
printf '%s' "$prior" > "$T/prior.txt"
git -C "$SRC" log --format=%H%x00%B%x1e "$h..$dsp" > "$T/log.txt"
if [ -x "$ROOT/node_modules/.bin/tsx" ]; then
  cat > "$T/prompt.ts" <<TS
import { readFileSync } from "node:fs";
import { buildReviewPrompt, priorRoundFromLog } from "$ROOT/src/review/reviewer.ts";
const prior = priorRoundFromLog(readFileSync("$T/log.txt", "utf8"), readFileSync("$T/prior.txt", "utf8"));
process.stdout.write(buildReviewPrompt("$dsp", "$h", true, prior));
TS
  pr=$("$ROOT/node_modules/.bin/tsx" "$T/prompt.ts")
  grep -q 'PRIOR ROUND' <<<"$pr"
  grep -q "${dsp:0:9} #2 src/x.ts:4 already clamps" <<<"$pr"
  grep -q 'x overflows' <<<"$pr"
  grep -q 'If it holds, drop the finding' <<<"$pr"
  grep -q "ancestors of ${c3:0:12} were already reviewed" <<<"$pr"
  echo "Review-Disputed in the re-review prompt ok"
else
  echo "tsx not installed: prompt check skipped (test/reviewer.test.ts covers it)"
fi
# 11-12: hand-written fixes (the CI owner's / the supervisor's own hotfixes) are not fixer rounds — only Loop: dev-fixer
k=$(cm src/k.ts "feature k"); for i in 1 2 3 4 5 6; do cm src/k.ts "owner fix $i" "Review-Fix-Of: $k" "Loop: supervisor" >/dev/null; done
hk=$(cm src/z.ts "later plain head")
test "$(fix_rounds "$hk" "evidence: src/k.ts:1")" = 0
echo "review churn checks passed"
# re-check of 6977d5574 #2: the Review-Fix-Of: chain hops count only fixer-agent links too — three CHAINED manual fixes are 0 rounds
m0=$(cm src/m.ts "feature m"); m1=$(cm src/m.ts "manual fix 1" "Review-Fix-Of: $m0" "Loop: supervisor")
m2=$(cm src/m.ts "manual fix 2" "Review-Fix-Of: $m1" "Loop: adhoc/ci-health"); m3=$(cm src/m.ts "manual fix 3" "Review-Fix-Of: $m2" "Loop: supervisor")
test "$(fix_rounds "$m3" "evidence: src/m.ts:1")" = 0
m4=$(cm src/m.ts "fixer fix" "Review-Fix-Of: $m3" "Loop: dev-fixer")
test "$(fix_rounds "$m4" "evidence: src/m.ts:1")" = 1
echo "chained manual fixes are no fixer rounds"
