#!/usr/bin/env bash
# Shared author routing; source for notify(), or pass <sha> <key> <thread>, message on stdin
# (<thread> = log: append the message to $STATE/dispatch.log only — fixer reports).
# Owner digest (owner 11-13): what fixers repaired in an author's code since their last notice. No separate wake: the
# list rides the author's next notice for anything (notify appends it and clears it once delivered).
digest_file() { local t=${1#mcp:}; printf '%s/repaired-digest/%s\n' "$STATE" "${t//[^A-Za-z0-9-]/_}"; }
digest_add() { # digest_add <thread> <line: "<repair sha> <finding>">
  [ -n "$1" ] && [ "$1" != - ] && [ -z "${DRY:-}" ] || return 0
  local f; f=$(digest_file "$1"); mkdir -p "${f%/*}"
  grep -qxF -- "$2" "$f" 2>/dev/null || printf '%s\n' "$2" >> "$f"
}
# Steer (owner 11-13): `t3 thread send` only queues ("nothing is interrupted"). steer_thread uses the T3 MCP tool
# t3_thread_send with mode "steer" (scripts/ci/t3-mcp.sh: a short-lived full-access MCP session, revoked after the call):
# the running turn gets the message now. A thread with no running turn gets it as a normal send (it starts a turn).
# Returns 1 (steer_err set) when steering is unavailable — notify then falls back to the normal send and logs it.
digest_done() { # digest_done <digest file> <n> → drop the first n entries (the delivered ones); keep the rest for the next notice
  [ -n "$1" ] && [ "${2:-0}" -gt 0 ] && [ -e "$1" ] || return 0
  sed -i "1,${2}d" "$1"; [ -s "$1" ] || rm -f "$1"
}
steer_thread() { # steer_thread <thread> <message>; sets steer_how (steered / started …)
  local t=$1 m=$2 c out mcp=${T3_MCP:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/t3-mcp.sh} cands=("$1")
  steer_how=""; steer_err=""
  [[ "$t" == mcp:* || "$t" == import:* ]] || cands+=("mcp:$t")
  for c in "${cands[@]}"; do
    if out=$(timeout 120 bash "$mcp" t3_thread_send "$(jq -nc --arg t "$c" --arg m "$m" '{threadId:$t,message:$m,mode:"steer"}')" 2>&1); then
      steer_how=$(jq -r '.delivery // "steered"' <<<"$out" 2>/dev/null || echo steered); return 0
    fi
    if grep -q 'no running turn' <<<"$out"; then   # idle: nothing to interrupt — a plain send starts its turn
      if out=$(timeout 120 bash "$mcp" t3_thread_send "$(jq -nc --arg t "$c" --arg m "$m" '{threadId:$t,message:$m,mode:"auto"}')" 2>&1); then
        steer_how="idle, $(jq -r '.delivery // "sent"' <<<"$out" 2>/dev/null || echo sent)"; return 0
      fi
    fi
    steer_err=$(tail -1 <<<"$out" | head -c 200)
  done
  return 1
}
notify() { # notify <sha> <key> <thread> <message>; sets notify_outcome = dup | dry | sent | skipped | undelivered
  # notify_mode=steer: a T3 thread is steered (interrupted) instead of queued — falls back to the normal send (logged)
  local sha=$1 key=$2 thread=$3 msg=$4 mark="$STATE/sent/$1.$2" dg dgn
  notify_outcome=dup
  # a skipped receipt stays "skipped" on later runs (re-check of 852eea2c5 #7: it read as dup = delivered)
  if [ -e "$mark" ]; then [ "$(head -1 "$mark" 2>/dev/null)" = skipped ] && notify_outcome=skipped; return 0; fi
  notify_outcome=undelivered
  if [ -n "${DRY:-}" ]; then notify_outcome=dry; echo "DRY notify${notify_mode:+ ($notify_mode)} $key ${sha:0:9} → '$thread': $(head -c 400 <<<"$msg" | tr '\n' ' ')"; return 0; fi
  dg=$(digest_file "$thread"); dgn=0
  if [ -s "$dg" ]; then
    dgn=$(head -20 "$dg" | wc -l); local dgrest; dgrest=$(( $(wc -l < "$dg") - dgn ))
    msg="$msg

(Also: since the last notice a fixer agent changed your code - fix commits / findings:
$(head -20 "$dg")$(if [ "$dgrest" -gt 0 ]; then printf '\n(%s more, attached to the next notice)' "$dgrest"; fi))"
  fi
  if [[ "$thread" =~ ^[0-9]{17,20}$ ]]; then
    if curl -fsS -m 70 -H 'content-type: application/json' "${WAKE_URL:-http://localhost:3011}/tool/wake_thread" \
        -d "$(jq -n --arg t "$thread" --arg p "$msg" --arg r "review-dispatch $key ${sha:0:9}" '{thread_id:$t,prompt:$p,reason:$r}')" \
        | jq -e '.ok == true' >/dev/null 2>&1; then log "sent $key ${sha:0:9} → discord $thread"; touch "$mark"; digest_done "$dg" "$dgn"; notify_outcome=sent
    else log "UNDELIVERED $key ${sha:0:9} → discord $thread (wake refused)"; return 1; fi
  elif [[ "$thread" =~ ^(mcp:|import:[A-Za-z]+:)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    # Agent-created T3 threads live under "mcp:<uuid>" (a trailer may carry either form);
    # sessions imported into T3 (the loops moved from Discord, 11-10) under "import:<provider>:<uuid>".
    local out
    if [ "${notify_mode:-}" = steer ]; then
      if steer_thread "$thread" "$msg"; then log "steered $key ${sha:0:9} → t3 $thread ($steer_how)"; touch "$mark"; digest_done "$dg" "$dgn"; notify_outcome=sent; return 0; fi
      log "steer unavailable for $key ${sha:0:9} → t3 $thread (${steer_err:-?}) — sent normally (queued)"
    fi
    if out=$(printf '%s\n' "$msg" | timeout 60 t3 thread send "$thread" - 2>&1) \
       || { [[ "$thread" != mcp:* && "$thread" != import:* ]] && out=$(printf '%s\n' "$msg" | timeout 60 t3 thread send "mcp:$thread" - 2>&1); }; then
      log "sent $key ${sha:0:9} → t3 $thread"; touch "$mark"; digest_done "$dg" "$dgn"; notify_outcome=sent
    elif grep -qE 'is archived|was not found|no longer available' <<<"$out"; then
      # An archived or missing thread can never receive messages: give up once instead of retrying every minute
      # (11-12: a wrong Thread: trailer was retried ~50 times; skipped notices are forwarded where it matters — revert outbox).
      log "SKIPPED $key ${sha:0:9} → t3 $thread ($(grep -oE 'is archived|was not found|no longer available' <<<"$out" | head -1))"; echo skipped > "$mark"; notify_outcome=skipped
    else log "UNDELIVERED $key ${sha:0:9} → t3 $thread (t3 thread send failed)"; return 1; fi
  else
    # not a thread id at all (empty / malformed Thread:) — permanent: skipped once, not retried every run
    log "SKIPPED $key ${sha:0:9}: Thread: '${thread}' is neither a Discord nor a T3 thread id"; echo skipped > "$mark"; notify_outcome=skipped
  fi
}

if [[ "${BASH_SOURCE[0]:-}" = "$0" || "$0" = "--" ]]; then
  set -euo pipefail
  : "${STATE:?STATE (the dispatcher state directory) is required}"
  mkdir -p "$STATE/sent"
  LOG=$STATE/dispatch.log
  log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }
  if [ "${3:-}" = log ]; then
    # A fixer's report (owner 11-12: reviewer → fixer → author): kept in the dispatch log and the fixer's own
    # thread, never sent to the authors — they hear from the dispatcher only when the fixer fails.
    msg=$(cat); [ -n "${DRY:-}" ] && { echo "DRY log ${2:-report} ${1:0:9}: $(head -c 400 <<<"$msg" | tr '\n' ' ')"; exit 0; }
    log "${2:-report} ${1:0:9}: $(head -c 3000 <<<"$msg" | tr '\n' ' ')"; exit 0
  fi
  notify "${1:?sha required}" "${2:?key required}" "${3:?thread required}" "$(cat)"
fi
