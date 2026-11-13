#!/usr/bin/env bash
set -euo pipefail
source scripts/ci/gh-cache.sh
t=$(mktemp -d)
trap 'command rm -rf "$t"' EXIT
mkdir "$t/bin"
cat > "$t/bin/gh" <<'BACKEND'
#!/usr/bin/env bash
if [ "$1" = run ] && [ "$2" = rerun ]; then
  echo failure > "$BACKEND_STATE"
else
  cat "$BACKEND_STATE"
fi
BACKEND
chmod +x "$t/bin/gh"
export PATH="$t/bin:$PATH" BACKEND_STATE="$t/state"
echo pass > "$BACKEND_STATE"
ghc_init "$t"
test "$(gh run list)" = pass
# Deterministic deletion failure, including when the test runs as root.
rm() { return 1; }
export -f rm
gh run rerun 1 2>"$t/error"
test -s "$t/error"
test "$(gh run list)" = failure
# The parent must also observe disabling performed in a subshell.
test -e "$GHC_RUN_DIR.disabled"
echo 'invalidation failure regression: PASS'
