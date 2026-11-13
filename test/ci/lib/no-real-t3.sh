# Sourced first by every test/ci/*.sh: the real T3 is out of reach — `t3` on PATH and $T3_MCP are stubs that fail the test
# loudly. A section that needs T3 behaviour installs its own stub (a t3() function, its own bin dir before PATH, or
# T3_MCP=<stub> for that call).
GUARD_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export GUARD_PID=$$
export PATH="$GUARD_LIB/bin:$PATH"
export T3_MCP="$GUARD_LIB/t3-real-blocked"
