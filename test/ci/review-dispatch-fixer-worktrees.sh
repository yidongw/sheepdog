#!/usr/bin/env bash
# Finished fixers' worktrees are removed (11-13: the dispatcher host's root disk filled with devfix-* worktrees nobody removed) — only
# those of fixers this dispatcher launched (a receipt matches the branch), only when the fixer is over and its work is
# pushed; never a live one, never a foreign worktree. Fixers symlink node_modules instead of copying it.
set -euo pipefail
ghm() { gh "$@"; }; ghc_note_jobs() { cat > /dev/null; }   # gh-cache.sh (the per-run memo of review-dispatch.sh): here the fake gh itself
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 (t3 CLI, T3 MCP) is unreachable from tests
command_not_found_handle() { echo "FAIL: command not found: $1 (a helper the test did not extract or stub)" >&2; kill -TERM $$ 2>/dev/null; exit 127; }
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC=$T/src STATE=$T/state MAIN=main FIXER_WT_ROOT=$T/wt FIXER_GATE_STALE_MIN=90
mkdir -p "$STATE/sent" "$FIXER_WT_ROOT"
LOG=$STATE/dispatch.log; log() { echo "$*" >> "$LOG"; }
eval "$(sed -n '/^fixer_worktrees_reap() {/,/^}/p' "$D")"
declare -F fixer_worktrees_reap >/dev/null || fail "no fixer_worktrees_reap: finished fixers' worktrees are never removed"
declare -A STATE_OF=()
fixer_thread_state() { echo "${STATE_OF[$1]:-}"; }
T3_NOTFOUND=""
timeout() { shift; "$@"; }   # the reaper calls `timeout 30 t3 …`: route it to the t3() stub
t3() { if [ -n "$T3_NOTFOUND" ]; then echo "Thread $3 was not found." >&2; return 1; fi; echo "t3: server unreachable" >&2; return 1; }
git init -q --bare "$T/remote.git"; git init -q -b main "$SRC"; git -C "$SRC" remote add origin "$T/remote.git"
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
g commit -q --allow-empty -m base; g push -q origin HEAD:refs/heads/main; g fetch -q origin
mkdir -p "$T/main_nm/pkg"; echo keep > "$T/main_nm/pkg/index.js"
n=0
mk() { # mk <state> [root] → creates commit S, a fixer worktree for it, its receipt; sets MS / MP (no subshell: STATE_OF, n)
  local st=$1 root=${2:-$FIXER_WT_ROOT} s tid path
  n=$((n + 1)); s=$(g commit-tree "$(g rev-parse 'HEAD^{tree}')" -p HEAD -m "S$n"); tid=mcp:0000000$n-0000-0000-0000-000000000000
  path=$root/devfix-${s:0:9}-mainfix-abcdef01$n
  g worktree add -q -b "devfix-${s:0:9}-mainfix-abcdef01$n" "$path" HEAD
  ln -s "$T/main_nm" "$path/node_modules"
  echo "$tid" > "$STATE/sent/$s.fixer-mainfix-abcdef01$n"; touch -d '-10 min' "$STATE/sent/$s.fixer-mainfix-abcdef01$n"
  STATE_OF[$tid]=$st
  MS=$s MP=$path
}
mk archived; S1=$MS P1=$MP                   # over + pushed → removed
mk running; S2=$MS P2=$MP                    # alive → kept
mk completed; S3=$MS P3=$MP                  # ended, receipt open, young → kept
mk archived; S4=$MS P4=$MP; echo x > "$P4/f"; git -C "$P4" add f; git -C "$P4" -c user.name=t -c user.email=t@t commit -q -m local   # unpushed → kept
mk archived "$T/elsewhere"; S5=$MS P5=$MP    # outside T3's worktree root → kept
mk ""; S6=$MS P6=$MP                         # unknown (t3 unreachable) → kept
g worktree add -q -b devfix-aaaaaaaaa-blocked "$FIXER_WT_ROOT/devfix-aaaaaaaaa-blocked" HEAD   # no receipt → kept
mk archived; S7=$MS P7=$MP; echo dirt > "$P7/scratch.txt"   # over, uncommitted junk → removed, logged
fixer_worktrees_reap
test ! -e "$P1" || fail "an archived, pushed fixer's worktree was kept"
if g rev-parse -q --verify "refs/heads/devfix-${S1:0:9}-mainfix-abcdef011" >/dev/null; then fail "its local branch was kept"; fi
grep -q "fixer worktree removed: $P1 (" "$LOG"
test -e "$P2" || fail "a RUNNING fixer's worktree was removed"
test -e "$P3" || fail "an ended fixer with an open receipt (young) was removed"
test -e "$P4" || fail "a worktree with unpushed commits was removed"; grep -q "fixer worktree $P4 (archived): 1 commit(s) on no remote ref — kept" "$LOG"
test -e "$P5" || fail "a worktree outside T3's worktree root was removed"
test -e "$P6" || fail "a worktree whose thread state is unknown (t3 unreachable) was removed"
test -e "$FIXER_WT_ROOT/devfix-aaaaaaaaa-blocked" || fail "a worktree without a dispatcher receipt was removed"
test ! -e "$P7" || fail "an archived fixer's worktree with uncommitted junk was kept"; grep -q "$P7 .*1 uncommitted file(s) discarded" "$LOG"
test "$(cat "$T/main_nm/pkg/index.js")" = keep || fail "removing a worktree touched the main checkout's node_modules"
echo 'archived + pushed → removed; running / open / unpushed / foreign / unknown → kept'
# the ended main fixer's receipt closes (its hotfix completes — its sha being on main says nothing for a main finding);
# "was not found" 90+ min after launch → gone → removed
g update-ref refs/heads/main "$S3"; g push -q -f origin main; g fetch -q origin
fixer_worktrees_reap
test -e "$P3" || fail "an ended MAIN fixer was removed just because its (main) sha is on main — its hotfix is still open"
touch "$STATE/sent/$S3.hotfix-complete"
touch -d '-2 hours' "$STATE/sent/$S6.fixer-mainfix-abcdef016"; T3_NOTFOUND=1
fixer_worktrees_reap
test ! -e "$P3" || fail "an ended fixer whose sha landed on main was kept"
test ! -e "$P6" || fail "a fixer T3 no longer finds (90+ min) was kept"
test -e "$P2"
echo 'closed receipt / not found → removed'
# re-check of c311b3766 #1: a fixer worktree whose directory is gone (moved / deleted → "prunable") or cannot be inspected
# never aborts the run (set -euo pipefail, as the dispatcher): stale metadata is pruned, a broken one is kept
mk archived; S8=$MS P8=$MP; mv "$P8" "$T/moved-away"
mk archived; S9=$MS P9=$MP; echo "gitdir: $T/nowhere" > "$P9/.git"
# not inside || / && (bash ignores set -e there): exactly how the dispatcher called it at top level
set +e; ( set -euo pipefail; fixer_worktrees_reap; echo reached-end > "$T/reap-ok" ); set -e
test -e "$T/reap-ok" || fail "a moved / broken fixer worktree aborted the run (set -e)"
if g worktree list --porcelain | grep -q "^worktree $P8\$"; then fail "the moved worktree's stale metadata was not pruned"; fi
test -e "$P9" || fail "a worktree that cannot be inspected was removed"; grep -q "fixer worktree $P9: cannot be inspected (git failed) — kept" "$LOG"
grep -qx 'fixer_worktrees_reap || log "fixer worktree cleanup failed (ignored; retried next run)"   # never aborts dispatch' "$D" || fail "the dispatcher's call can abort the run"
echo 'moved / broken worktrees: no abort, stale metadata pruned'

# fixer_thread_state reads the status line only: a LIVE fixer whose transcript contains "no longer available" (every fixer's
# first message embeds review-notify.sh, which does) is not "gone" (11-13: judged gone → gate released, a second fixer)
eval "$(sed -n '/^fixer_thread_state() {/,/^}/p' "$D")"
t3() { local m=10 a; for a in "$@"; do [ "${prev:-}" = --messages ] && m=$a; prev=$a; done; prev=""
  echo "main: fix the findings"; echo "$3  running  codex/gpt-6.1-sol"
  if [ "$m" != 0 ]; then echo; echo "[user]"; echo "  elif grep -qE 'is archived|was not found|no longer available' <<<\"\$out\"; then"; fi; }
test "$(fixer_thread_state mcp:11111111-1111-1111-1111-111111111111)" = running || fail "a running fixer whose transcript mentions 'no longer available' is judged $(fixer_thread_state mcp:11111111-1111-1111-1111-111111111111)"
t3() { echo "Thread $3 is no longer available."; return 1; }
test "$(fixer_thread_state mcp:22222222-2222-2222-2222-222222222222)" = gone
echo 'thread state: status line only'
# fixers symlink node_modules (no copy, no cp -al)
grep -q 'ln -s ${SRC:-<main checkout>}/node_modules node_modules' "$D" || fail "the fixer prompt does not tell fixers to symlink node_modules"
if grep -q 'with cp -al and rename it to node_modules' "$D"; then fail "the fixer prompt still copies node_modules (cp -al)"; fi
echo 'fixer worktree checks passed'
