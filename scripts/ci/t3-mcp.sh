#!/usr/bin/env bash
# t3-mcp.sh — call one tool of the local T3 server's MCP endpoint (the same tools agents use: t3_thread_send with
# mode "steer", t3_thread_configure with a model's effort option, ...). The `t3 thread` CLI only queues messages
# ("nothing is interrupted") and cannot set a reasoning effort; the dispatcher needs both (owner 11-13).
#
#   t3-mcp.sh <tool> <arguments JSON>   → prints the tool's structuredContent (JSON); exit 1 on any failure
#
# Auth: the documented MCP OAuth flow, approved with a one-time pairing code — the same full-access MCP client session
# the `t3 thread` CLI issues itself in-process (`t3 auth session issue` sessions are refused by /mcp, and an
# approval-required session may not send to / configure / interrupt full-access threads: runtime_mode_escalation_denied).
# Per call: `t3 auth pairing create` (one-time, TTL 5m, the scopes of full access) → register a client (unique name) →
# PKCE authorization decided with that code → token → the tool call → the session is revoked (found by its unique
# label in `t3 auth session list`). Tokens and codes never reach argv, stdout or a log: they live in files of a
# private temp dir (mode 0700, deleted on exit) and reach curl as header / data files.
# T3_MCP_FAKE=<script>: tests replace the whole call with that script (args: <tool> <json>).
set -uo pipefail
tool=${1:?tool required}; args=${2:-'{}'}
if [ -n "${T3_MCP_FAKE:-}" ]; then exec "$T3_MCP_FAKE" "$tool" "$args"; fi
rt=${T3CODE_HOME:-$HOME/.t3}/userdata/server-runtime.json
origin=$(jq -r '.origin // empty' "$rt" 2>/dev/null) || exit 1
[ -n "$origin" ] || { echo "t3-mcp: no running T3 server ($rt)" >&2; exit 1; }
tmp=$(mktemp -d) || exit 1; chmod 700 "$tmp"; umask 077
label="review-dispatch-$$-$(date +%s%N | tail -c 7)"
pid=""
cleanup() {
  local sid
  sid=$(timeout 30 t3 auth session list --json 2>/dev/null | jq -r --arg l "$label" '[.. | objects | select((.client.label? // .label? // "") == $l) | .sessionId? // empty][0] // empty' 2>/dev/null || true)
  if [ -n "$sid" ]; then timeout 30 t3 auth session revoke "$sid" >/dev/null 2>&1 || echo "t3-mcp: could not revoke session $sid" >&2
  elif [ -s "$tmp/auth" ]; then echo "t3-mcp: session $label not found to revoke" >&2; fi
  [ -n "$pid" ] && timeout 30 t3 auth pairing revoke "$pid" >/dev/null 2>&1   # an unspent code (a failed approval)
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "t3-mcp: $*" >&2; exit 1; }
resource=$(curl -fsS -m 15 "$origin/.well-known/oauth-protected-resource/mcp" | jq -r '.resource // empty') || fail "no OAuth metadata"
timeout 30 t3 auth pairing create --scope orchestration:read --scope orchestration:operate --scope settings:write \
  --scope source-control:write --ttl 5m --label "$label" --json > "$tmp/pair" 2>/dev/null || fail "could not create a pairing code"
pid=$(jq -r '.id // empty' "$tmp/pair"); jq -r '.credential // empty' "$tmp/pair" > "$tmp/code"; rm -f "$tmp/pair"
[ -s "$tmp/code" ] || fail "no pairing code issued"
redirect="http://127.0.0.1:9/cb"
cid=$(curl -fsS -m 15 -H 'content-type: application/json' "$origin/oauth/mcp/register" \
  -d "$(jq -nc --arg n "$label" --arg r "$redirect" '{client_name:$n,redirect_uris:[$r],token_endpoint_auth_method:"none"}')" | jq -r '.client_id // empty') || fail "client registration refused"
[ -n "$cid" ] || fail "no client id"
openssl rand -base64 48 | tr -d '\n=' | tr '/+' '_-' > "$tmp/verifier"
chal=$(tr -d '\n' < "$tmp/verifier" | openssl dgst -sha256 -binary | openssl base64 | tr -d '\n=' | tr '/+' '_-')
state=$(openssl rand -hex 8)
jq -nc --arg c "$cid" --arg r "$redirect" --arg ch "$chal" --arg s "$state" --arg res "$resource" --rawfile code "$tmp/code" \
  '{authorization:{response_type:"code",client_id:$c,redirect_uri:$r,code_challenge:$ch,code_challenge_method:"S256",state:$s,resource:$res},decision:{_tag:"pairing-code",access:"full-access",code:($code|rtrimstr("\n"))}}' > "$tmp/decision"
curl -fsS -m 15 -H 'content-type: application/json' "$origin/oauth/mcp/decision" -d @"$tmp/decision" > "$tmp/redir" 2>/dev/null || fail "the approval was refused"
rm -f "$tmp/decision" "$tmp/code"; pid=""   # the code is spent
jq -r '.redirectTo // empty' "$tmp/redir" | sed -nE 's/.*[?&]code=([^&]+).*/\1/p' > "$tmp/authcode"; rm -f "$tmp/redir"
[ -s "$tmp/authcode" ] || fail "no authorization code"
{ printf 'grant_type=authorization_code&client_id=%s&redirect_uri=%s&resource=%s&code=' "$(jq -rn --arg v "$cid" '$v|@uri')" "$(jq -rn --arg v "$redirect" '$v|@uri')" "$(jq -rn --arg v "$resource" '$v|@uri')"
  tr -d '\n' < "$tmp/authcode"; printf '&code_verifier='; tr -d '\n' < "$tmp/verifier"; } > "$tmp/tokreq"
curl -fsS -m 15 -H 'content-type: application/x-www-form-urlencoded' "$origin/oauth/mcp/token" --data-binary @"$tmp/tokreq" > "$tmp/tok" 2>/dev/null || fail "token exchange refused"
rm -f "$tmp/tokreq" "$tmp/authcode" "$tmp/verifier"
printf 'Authorization: Bearer %s\n' "$(jq -r '.access_token // empty' "$tmp/tok")" > "$tmp/auth"; rm -f "$tmp/tok"
grep -q 'Bearer .' "$tmp/auth" || fail "no access token"
post() { # post <json> → the JSON-RPC response (plain JSON or the data: line of an event stream)
  curl -sS -m "${T3_MCP_TIMEOUT:-60}" -H @"$tmp/auth" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -H 'mcp-protocol-version: 2025-06-18' ${msid:+-H "mcp-session-id: $msid"} -D "$tmp/hdr" "$origin/mcp" -d "$1" | sed -nE 's/^data: //p; /^\{/p'
}
msid=""
init=$(post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"review-dispatch","version":"1"}}}')
jq -e '.result' >/dev/null 2>&1 <<<"$init" || { echo "t3-mcp: initialize refused: $(head -c 200 <<<"$init")" >&2; exit 1; }
msid=$(sed -nE 's/^[Mm]cp-[Ss]ession-[Ii]d: *([^[:space:]]+).*/\1/p' "$tmp/hdr" | head -1)
post '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
res=$(post "$(jq -nc --arg t "$tool" --argjson a "$args" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$t,arguments:$a}}')")
if ! jq -e '.result and (.result.isError != true)' >/dev/null 2>&1 <<<"$res"; then
  echo "t3-mcp: $tool failed: $(jq -r '(.result.content[0].text // .error.message // .) | tostring' <<<"$res" 2>/dev/null | head -c 300)" >&2; exit 1
fi
jq -c '.result.structuredContent // (.result.content[0].text | fromjson? ) // .result' <<<"$res"
