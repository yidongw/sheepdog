#!/usr/bin/env bash
# Cutover migration must never turn an uncertain activation boundary into permanent exclusion of a blocked fix.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
cd "$(dirname "$0")/../.."
D=scripts/ci/review-dispatch.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
fns() { local n; for n in "$@"; do sed -n "/^$n() {/,/^}/p" "$D"; done; }
eval "$(fns main_heads_base main_head_candidate main_arrivals hotfix_candidates)"; MAIN_WINDOW_SEC=604800
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MAIN=main DRY=""
log() { :; }
g() { git -C "$SRC" -c user.name=t -c user.email=t@t "$@"; }
main_walk_base() { echo "$ROOT"; }
recheck_run() { [ "$1" = "$FIX" ] && echo 6; }
review_job_state() { echo failure; }

check_case() (
  local scenario=$1 activation b candidates pass
  activation=$(( $(date +%s) - 3600 ))
  SRC=$T/$scenario/src STATE=$T/$scenario/state
  mkdir -p "$SRC" "$STATE/sent"
  git init -q -b main "$SRC"
  g commit -q --allow-empty -m root; ROOT=$(g rev-parse HEAD)
  g commit -q --allow-empty -m old; OLD=$(g rev-parse HEAD)
  g config core.logAllRefUpdates true
  GIT_COMMITTER_DATE="@$((activation - 1)) +0000" g update-ref --create-reflog refs/remotes/origin/main "$OLD"
  # The fix was CREATED before activation and only reached main afterwards: commit timestamps are not a fallback.
  GIT_COMMITTER_DATE="@$((activation - 100)) +0000" g commit -q --allow-empty -m fix -m "Review-Fix-Of: $OLD"
  FIX=$(g rev-parse HEAD)
  echo "$activation" > "$STATE/main-heads-since"
  case "$scenario" in
    same-second|no-prior)
      # Write activation first, then update main in that same second, without any wall-clock timing dependency.
      GIT_COMMITTER_DATE="@$activation +0000" g update-ref refs/remotes/origin/main "$FIX" ;;
    *) GIT_COMMITTER_DATE="@$((activation + 1)) +0000" g update-ref refs/remotes/origin/main "$FIX" ;;
  esac
  case "$scenario" in
    missing-reflog)
      g reflog expire --expire=all refs/remotes/origin/main
      g config core.logAllRefUpdates false ;;
    no-prior)
      g reflog expire --expire=all refs/remotes/origin/main
      GIT_COMMITTER_DATE="@$activation +0000" g update-ref refs/remotes/origin/main "$OLD"
      GIT_COMMITTER_DATE="@$activation +0000" g update-ref refs/remotes/origin/main "$FIX" ;;
    invalid-state) echo unknown > "$STATE/main-heads-since" ;;
    fresh) rm "$STATE/main-heads-since" ;;
    persisted) echo "$OLD" > "$STATE/main-heads-base" ;;
    dry) DRY=1 ;;
  esac
  # Exercise two dispatcher invocations: a failed migration must not silently become a fresh activation next time.
  for pass in 1 2; do
    unset main_heads_b
    b=$(main_heads_base)
    candidates=$(hotfix_candidates)
    case "$scenario" in
      fresh)
        [ "$b" = "$FIX" ] || fail "$scenario: first activation did not record the main tip"
        [ -z "$candidates" ] || fail "$scenario: existing main head was treated as new" ;;
      *)
        [ "$candidates" = "$FIX" ] || fail "$scenario: blocked post-activation fix was excluded (base=${b:-unset}, pass=$pass)"
        case "$scenario" in
          same-second|persisted|dry)
            [ "$b" = "$OLD" ] || fail "$scenario: did not select the proven pre-activation boundary" ;;
          *) [ -z "$b" ] || fail "$scenario: invented a boundary without pre-activation evidence" ;;
        esac ;;
    esac
    case "$scenario" in
      missing-reflog|no-prior|invalid-state|dry)
        [ ! -e "$STATE/main-heads-base" ] || fail "$scenario: persisted an unsafe boundary or wrote during DRY"
        [ -e "$STATE/main-heads-since" ] || fail "$scenario: lost the legacy activation marker" ;;
      *) [ "$(cat "$STATE/main-heads-base")" = "$b" ] || fail "$scenario: did not persist the boundary" ;;
    esac
  done
  echo "ok - $scenario"
)
if [ "$#" -gt 0 ]; then
  check_case "$1"
else
  for scenario in missing-reflog same-second no-prior invalid-state fresh persisted dry; do check_case "$scenario"; done
fi
