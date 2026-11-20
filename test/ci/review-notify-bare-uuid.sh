#!/usr/bin/env bash
# A bare-uuid Thread: trailer reaches the live thread under whichever T3 form it has: as is, mcp:<uuid>, or
# import:claudeAgent:<uuid> (11-20: an imported Claude session's bare uuid was judged missing and fell back).
set -euo pipefail
source "$(dirname "$0")/lib/no-real-t3.sh"   # the real T3 is out of reach; this test puts its own t3 stub first on PATH
cd "$(dirname "$0")/../.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state/sent"
U=3afd24a5-4ea6-48dd-b0de-6f21ac2f385a
cat > "$T/bin/t3" <<SH
#!/usr/bin/env bash
# fake t3: only the form in \$LIVE exists; record every attempt
echo "\$3" >> "$T/attempts"; cat > /dev/null
[ "\$3" = "\$LIVE" ] && exit 0
echo "Thread \$3 was not found"; exit 1
SH
chmod +x "$T/bin/t3"
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { rm -f "$T/attempts" "$T/state/sent/"*; printf 'hello\n' | LIVE=$1 PATH="$T/bin:$PATH" STATE="$T/state" bash scripts/ci/review-notify.sh abcdef0123456789abcdef0123456789abcdef01 k1 "$2"; }
run "import:claudeAgent:$U" "$U"
grep -q "sent k1 abcdef012 → t3 $U" "$T/state/dispatch.log" || fail "bare uuid of an imported session was not delivered: $(cat "$T/state/dispatch.log")"
grep -qx "import:claudeAgent:$U" "$T/attempts" || fail "import:claudeAgent form not tried"
: > "$T/state/dispatch.log"
run "mcp:$U" "$U"
grep -q "sent k1" "$T/state/dispatch.log" || fail "bare uuid of an agent thread not delivered"
! grep -qx "import:claudeAgent:$U" "$T/attempts" || fail "tried further forms after delivery"
: > "$T/state/dispatch.log"
run "nobody" "$U"
grep -q "SKIPPED k1 abcdef012 → t3 $U (was not found)" "$T/state/dispatch.log" || fail "unknown uuid not skipped: $(cat "$T/state/dispatch.log")"
echo "bare uuid: tried as is, mcp:, import:claudeAgent:"

# re-check of bdf70d1cd #1: one form failing transiently (the others missing) keeps the notice retryable — no receipt
cat > "$T/bin/t3" <<SH
#!/usr/bin/env bash
echo "\$3" >> "$T/attempts"; cat > /dev/null
[ "\$3" = "mcp:$U" ] && { echo "connection refused"; exit 1; }
echo "Thread \$3 was not found"; exit 1
SH
chmod +x "$T/bin/t3"; : > "$T/state/dispatch.log"; rm -f "$T/attempts" "$T/state/sent/"*
rc=0; printf 'hello\n' | PATH="$T/bin:$PATH" STATE="$T/state" bash scripts/ci/review-notify.sh abcdef0123456789abcdef0123456789abcdef01 k2 "$U" || rc=$?
[ "$rc" != 0 ] || fail "a transient failure was not reported as undelivered"
grep -q "UNDELIVERED k2" "$T/state/dispatch.log" || fail "no UNDELIVERED log: $(cat "$T/state/dispatch.log")"
! grep -q "SKIPPED k2" "$T/state/dispatch.log" || fail "a transient failure wrote a permanent skip"
[ -z "$(ls "$T/state/sent/" 2>/dev/null)" ] || fail "a receipt was written for a retryable notice: $(ls "$T/state/sent/")"
echo "bare uuid: a transient failure of one form stays retryable"
