#!/usr/bin/env bash
#
# Stream NEW aiur ALERT events out of every active agent's structured NDJSON log,
# one JSON line per alert, as they fire — so the operator agent running aiur can
# post the "why" in chat in near real time instead of waiting for the 5-minute
# status tick. This is the immediacy half of the alert relay; `aiurdev watch`'s
# ACTIONABLE section is the periodic floor/backstop.
#
# Unlike a one-shot board snapshot, this is LONG-LIVED: it keeps
# running and prints each new alert as it lands. Drive it from the operator
# agent's harness as a streaming background watch (the Monitor tool) so every
# printed line becomes one in-chat notification. It never drives the status
# cadence (that stays an armed /loop), so it does not violate the monitor skill's
# "armed timer, not passive event-waiting" cadence rule — it only adds immediacy
# to alerts, which the periodic `aiurdev watch` tick still catches as a floor.
#
# Reuses the #651/#662 structured alert feed: it reads each active agent's
# logs/agent.ndjson and the same alert schema
#   {"event":"alert","timestamp":"...","name":"ticket.43.agent.paused",
#    "reason":"Agent paused","severity":"warning","needs_attention":true,
#    "source_ticket_id":"43",...}
# The central alerts.ndjson is written only for remote worker_host agents and is
# out of scope for Phase 1 (local --bg runs write only agent.ndjson).
#
# Output (oldest->newest, one per new alert; same shape as the alert feed plus
# a timestamp so the chat line can say when it fired):
#   {"timestamp":"...","ticket":"43","source_ticket_id":"43","agent":"43",
#    "reason":"Agent paused","severity":"warning","topic":"ticket.43.agent.paused",
#    "name":"ticket.43.agent.paused","needs_attention":true}
#
# New alerts are detected by tracking, per feed file, the count of alert lines
# already emitted — held IN MEMORY for the life of the process (no persisted
# cursor, so no cross-run state collisions and nothing to grow unbounded). At
# startup each existing file is baselined to its current count (history is
# skipped — it is covered by the `aiurdev watch` tick), so only
# alerts that fire AFTER watching began are streamed.
#
# Tune with env vars:
#   AIUR_ALERT_POLL            (default 2)    — seconds between scans
#   AIUR_ALERT_WATCH_ITERS     (default 0)    — stop after N scans (0 = forever; for tests)
#   AIUR_ALERT_RELAY_BACKLOG   (default 0)    — 1 = also emit alerts already present at startup
#   AIUR_ALERT_NEEDS_ATTENTION (default 0)    — 1 = Phase 2: relay only needs_attention:true alerts
#
# Usage: watch-alerts.sh [path/to/config]
#   Defaults to ./.aiur/config (current layout), falling back to ./.aiurconfig (legacy).
set -euo pipefail

config="${1:-}"
if [ -z "$config" ]; then
  if [ -f .aiur/config ]; then config=".aiur/config"
  elif [ -f .aiurconfig ]; then config=".aiurconfig"
  else config=".aiur/config"; fi
fi
poll="${AIUR_ALERT_POLL:-2}"
max_iters="${AIUR_ALERT_WATCH_ITERS:-0}"
relay_backlog="${AIUR_ALERT_RELAY_BACKLOG:-0}"
need_only="${AIUR_ALERT_NEEDS_ATTENTION:-0}"

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

# --- Resolve candidate workspace roots (same as the alert feed) -------------
config_root=""
if [ -f "$config" ]; then
  config_root="$(awk '
    /^[^[:space:]#]/ { in_ws = ($1 == "workspace:") }
    in_ws && $1 == "root:" { print $2; exit }
  ' "$config")"
  config_root="${config_root/#\~/$HOME}"
fi
home_root="$HOME/.aiur/workspaces"

roots=()
add_root() {
  local r="$1"
  [ -n "$r" ] || return 0
  [ -d "$r" ] || return 0
  local existing
  for existing in "${roots[@]:-}"; do
    [ "$existing" = "$r" ] && return 0
  done
  roots+=("$r")
}
add_root "$config_root"
add_root "$home_root"

# --- JSON helpers (jq-less fallback escapes \ and ") ------------------------
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Per-file alert-line-count cursors, kept as parallel indexed arrays so this
# stays portable to the bash 3.2 that ships on macOS (no associative arrays).
seen_paths=()
seen_counts=()

# Echo the index of $1 in seen_paths, or -1.
index_of() {
  local target="$1" i=0
  for p in "${seen_paths[@]:-}"; do
    [ "$p" = "$target" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  printf '%s' -1
}

# Map one raw alert ndjson line to the structured output line; honour the
# needs_attention-only Phase-2 filter. Mirrors the alert feed's field handling
# (kept in sync deliberately) and adds the timestamp.
emit_alert_line() {
  local line="$1" agent="$2"
  local ts msg name reason severity need src_ticket tkt

  if [ "$have_jq" -eq 1 ]; then
    local parsed
    parsed="$(printf '%s' "$line" | jq -r 'select(.event=="alert") | [(.timestamp // ""), (.message // ""), (.topic // .name // ""), (.reason // ""), (.severity // "info"), (if .needs_attention == true then "true" else "false" end), (.source_ticket_id // "")] | join("\u001f")' 2>/dev/null || true)"
    [ -n "$parsed" ] || return 0
    IFS=$'\x1f' read -r ts msg name reason severity need src_ticket <<<"$parsed"
  else
    name="$(printf '%s' "$line" | sed -n 's/.*"topic":"\([^"]*\)".*/\1/p')"
    [ -n "$name" ] || name="$(printf '%s' "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
    [ -n "$name" ] || return 0
    ts="$(printf '%s' "$line" | sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p')"
    msg="$(printf '%s' "$line" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')"
    reason="$(printf '%s' "$line" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')"
    severity="$(printf '%s' "$line" | sed -n 's/.*"severity":"\([^"]*\)".*/\1/p')"
    src_ticket="$(printf '%s' "$line" | sed -n 's/.*"source_ticket_id":"\([^"]*\)".*/\1/p')"
    if printf '%s' "$line" | grep -q '"needs_attention":true'; then need="true"; else need="false"; fi
  fi

  [ "$need_only" != "1" ] || [ "$need" = "true" ] || return 0

  tkt="$src_ticket"
  [ -n "$tkt" ] || tkt="$(printf '%s' "$name" | sed -n 's/^ticket\.\([^.]*\)\..*/\1/p')"
  [ -n "$tkt" ] || tkt="$agent"
  [ -n "$reason" ] || reason="$msg"
  [ -n "$reason" ] || reason="${name##*.}"
  [ -n "$severity" ] || severity="info"

  if [ "$have_jq" -eq 1 ]; then
    jq -cn \
      --arg timestamp "$ts" \
      --arg ticket "$tkt" \
      --arg source_ticket_id "$tkt" \
      --arg agent "$agent" \
      --arg reason "$reason" \
      --arg severity "$severity" \
      --arg topic "$name" \
      --arg name "$name" \
      --argjson needs_attention "$need" \
      '{timestamp:$timestamp,ticket:$ticket,source_ticket_id:$source_ticket_id,agent:$agent,reason:$reason,severity:$severity,topic:$topic,name:$name,needs_attention:$needs_attention}'
  else
    printf '{"timestamp":"%s","ticket":"%s","source_ticket_id":"%s","agent":"%s","reason":"%s","severity":"%s","topic":"%s","name":"%s","needs_attention":%s}\n' \
      "$(json_escape "$ts")" "$(json_escape "$tkt")" "$(json_escape "$tkt")" \
      "$(json_escape "$agent")" "$(json_escape "$reason")" "$(json_escape "$severity")" \
      "$(json_escape "$name")" "$(json_escape "$name")" "$need"
  fi
}

# One scan across all roots: emit newly-appended alerts, advance cursors.
scan_once() {
  local first_scan="$1"
  local seen_logs="" root log abs ws id total idx prior snapshot

  for root in "${roots[@]:-}"; do
    [ -n "$root" ] || continue
    while IFS= read -r log; do
      [ -f "$log" ] || continue
      abs="$(cd "$(dirname "$log")" 2>/dev/null && pwd)/$(basename "$log")"
      case "$seen_logs" in
        *"|${abs}|"*) continue ;;
      esac
      seen_logs="${seen_logs}|${abs}|"

      ws="$(dirname "$(dirname "$abs")")"
      id="$(basename "$ws")"

      # Snapshot the alert lines ONCE per scan, and derive BOTH the count and the
      # lines we emit from this single read. Two separate greps (one to count,
      # one to emit) could disagree if a line lands between them — double-emitting
      # an alert or drifting the cursor. A trailing line with no terminating
      # newline is a half-written append still mid-flush: drop it from the
      # snapshot (sed '$d') so we never count or emit — and advance past — a
      # partial line and lose it. It re-appears complete on the next scan.
      if [ -n "$(tail -c1 "$abs" 2>/dev/null)" ]; then
        snapshot="$(sed '$d' "$abs" 2>/dev/null | grep '"event":"alert"' || true)"
      else
        snapshot="$(grep '"event":"alert"' "$abs" 2>/dev/null || true)"
      fi
      if [ -z "$snapshot" ]; then
        total=0
      else
        total="$(printf '%s\n' "$snapshot" | grep -c '"event":"alert"' || true)"
      fi
      total="${total:-0}"

      idx="$(index_of "$abs")"
      if [ "$idx" -lt 0 ]; then
        # First time we see this file. Baseline to current count so history is
        # skipped — unless this is a brand-new file discovered AFTER startup (a
        # newly dispatched agent), whose alerts all fired after watching began,
        # or the operator opted into the backlog.
        if [ "$first_scan" -eq 1 ] && [ "$relay_backlog" != "1" ]; then
          prior="$total"
        else
          prior=0
        fi
        seen_paths+=("$abs")
        seen_counts+=("$prior")
        idx=$((${#seen_paths[@]} - 1))
      fi

      prior="${seen_counts[$idx]}"
      # A shrunk/rotated file: re-baseline rather than replay from the top.
      if [ "$total" -lt "$prior" ]; then
        seen_counts[$idx]="$total"
        continue
      fi
      [ "$total" -gt "$prior" ] || continue

      while IFS= read -r line; do
        [ -n "$line" ] || continue
        emit_alert_line "$line" "$id"
      done < <(printf '%s\n' "$snapshot" | tail -n "+$((prior + 1))")

      seen_counts[$idx]="$total"
    done < <(find "$root" -maxdepth 6 -type f -name agent.ndjson 2>/dev/null)
  done
}

# --- Watch loop -------------------------------------------------------------
iter=0
first=1
while :; do
  scan_once "$first"
  first=0
  iter=$((iter + 1))
  if [ "$max_iters" -gt 0 ] && [ "$iter" -ge "$max_iters" ]; then
    break
  fi
  sleep "$poll"
done
