#!/usr/bin/env bash
# A log read before completion confirmation must be fetched again before reuse,
# within the same memo and in the next dispatcher run. Exercise real ghm calls.
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/scripts/ci/gh-cache.sh"
T=$(mktemp -d); trap 'ghc_done; rm -rf "$T"' EXIT
export FX=$T/fx
mkdir -p "$FX" "$T/bin"
cat > "$T/bin/gh" <<'BACKEND'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'api repos/o/r/actions/jobs/42/logs') echo log >> "$FX/calls"; cat "$FX/log" ;;
  'api repos/o/r/actions/runs/7/jobs') cat "$FX/jobs" ;;
  *) exit 1 ;;
esac
BACKEND
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
for initial in unconfirmed recent legacy; do
  ghc_init "$T/$initial"
  # Existing unversioned files may already contain a prefix from the old code.
  if [ "$initial" = legacy ]; then printf 'legacy prefix\n' > "$GHC_DIR/logs/42"; fi
  printf 'partial log\n' > "$FX/log"; : > "$FX/calls"
  if [ "$initial" = recent ]; then
    jq -nc --arg t "$(date -u +%FT%TZ)" '{jobs:[{id:42,status:"completed",completed_at:$t}]}' > "$FX/jobs"
    ghm api repos/o/r/actions/runs/7/jobs >/dev/null
  fi
  ghm api repos/o/r/actions/jobs/42/logs > "$T/early"
  cmp -s "$FX/log" "$T/early" || fail "$initial: early log changed"
  [ ! -e "$GHC_DIR/logs/final.42" ] || fail "$initial: early log persisted"
  printf 'complete\000\377\r\nreview-gate: BLOCKED #1 regression [should]: final findings\n' > "$FX/log"
  jq -nc --arg t "$(date -u -d '5 minutes ago' +%FT%TZ)" '{jobs:[{id:42,status:"completed",completed_at:$t}]}' > "$FX/jobs"
  # The dispatcher records completion from its fresh jobs read. Do not clear
  # the memo containing the vulnerable prefix, or its jobs/listing evidence.
  ghc_note_jobs < <(gh api repos/o/r/actions/runs/7/jobs)
  ghm api repos/o/r/actions/jobs/42/logs > "$T/final"
  cmp -s "$FX/log" "$T/final" || fail "$initial: the earlier prefix was promoted without refetching"
  [ "$(wc -l < "$FX/calls")" = 2 ] || fail "$initial: expected two upstream log fetches"
  ghc_done; ghc_init "$T/$initial"
  ghm api repos/o/r/actions/jobs/42/logs > "$T/next"
  cmp -s "$FX/log" "$T/next" || fail "$initial: next run reused the partial log"
  [ "$(wc -l < "$FX/calls")" = 2 ] || fail "$initial: final log was not reused"
  ghc_done
  echo "ok - $initial log refetched after completion; complete bytes reused next run"
done
