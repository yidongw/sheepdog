#!/usr/bin/env bash
# One commit message's Loop:/Thread:/Verify: trailer rules, for a repository's local commit-msg hook (the same rules
# scripts/ci/commit-gates.sh enforces in CI: 11-10 a fixer's `Verify: <text on one line>` passed every local hook and
# was only refused on main by CI, which stopped autodeploy).
#
# Usage: check-trailers.sh [<message-file>]   (stdin when omitted)
# Prints one line per problem; exit 0 ok · 1 problem(s).
set -euo pipefail

cmsg="$(cat "${1:-/dev/stdin}")"
bad=0
miss=""
grep -qiE '^Loop:[[:space:]]*[^[:space:]]' <<<"$cmsg" || miss="Loop:"
# Verify: is a checklist header — the line itself is bare, the checked items follow it
grep -qiE '^Verify:[[:space:]]*$' <<<"$cmsg" || miss="$miss Verify:"
grep -qiE '^Thread:[[:space:]]*[^[:space:]]' <<<"$cmsg" || miss="$miss Thread:"
if [ -n "$miss" ]; then
  echo "missing obligation-ledger trailer(s): $miss (#294) — Verify: must be a bare line followed by '- [x] …' items"
  bad=1
fi
tval="$(printf '%s\n' "$cmsg" | grep -iE '^Thread:' | tail -1 | sed -E 's/^[Tt]hread:[[:space:]]*//' | tr -d '[:space:]' || true)"
# Author thread: a numeric Discord thread id, or a T3 thread id (uuid; loops moved to T3 11-10):
# `mcp:<uuid>` for agent-created threads, `import:<provider>:<uuid>` for sessions imported into T3.
# A Thread: no one can be woken at is refused (owner 11-10): blocked findings went nowhere
# ("t3code-adhoc", a branch slug), so the author never learned the commit was stuck.
if [ -n "$tval" ] && ! grep -qE '^([0-9]{17,20}|(mcp:|import:[A-Za-z]+:)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$' <<<"$tval"; then
  echo "Thread:'$tval' is neither a Discord nor a T3 thread id — review findings can't reach this author (Discord: the thread's numeric id; T3: the thread's uuid)"
  bad=1
fi
exit "$bad"
