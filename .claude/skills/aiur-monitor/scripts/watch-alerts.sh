#!/usr/bin/env bash
#
# Stream NEW aiur ALERT events out of every active agent's structured NDJSON log,
# one JSON line per alert, as they fire — so the Executor agent running aiur can
# post the "why" in chat in near real time instead of waiting for the 5-minute
# status tick. This is the immediacy half of the alert relay; `aiurdev watch`'s
# ACTIONABLE section is the periodic floor/backstop.
#
# Unlike a one-shot board snapshot, this is LONG-LIVED: it keeps
# running and prints each new alert as it lands. Drive it from the Executor
# agent's harness as a streaming background watch (the Monitor tool) so every
# printed line becomes one in-chat notification. It never drives the status
# cadence (which stays armed through the host's recurring mechanism), so it does
# not violate the "timer, not passive event-waiting" rule — it adds immediacy
# to alerts, which the periodic `aiurdev watch` tick still catches as a floor.
#
# Reuses the #651/#662 structured alert feed: it reads each active agent's
# logs/agent.ndjson and the same alert schema
#   {"event":"alert","timestamp":"...","name":"ticket.43.agent.paused",
#    "reason":"Agent paused","severity":"warning","needs_attention":true,
#    "source_ticket_id":"43",...}
# Remote-worker and workspace-less alerts have no local per-workspace record and
# land in the central alerts.ndjson, which is out of scope here. The recurring
# server-side `aiurdev watch` cadence is the backstop for those alerts.
#
# Output (oldest->newest, one per new alert; same shape as the alert feed plus
# a timestamp so the chat line can say when it fired):
#   {"timestamp":"...","ticket":"43","source_ticket_id":"43","agent":"43",
#    "reason":"Agent paused","severity":"warning","topic":"ticket.43.agent.paused",
#    "name":"ticket.43.agent.paused","needs_attention":true,
#    "operator_decision":false}
#
# `operator_decision:true` marks the canonical `attention.operator-decision`
# topic so the Executor relay can distinguish an unanswered scope or acceptance
# question from a routine pause and fan it out to the active surfaces.
#
# New alerts are detected by tracking, per feed file, the count of alert lines
# already emitted — held IN MEMORY for the life of the process (no persisted
# cursor, so no cross-run state collisions and nothing to grow unbounded). At
# startup each existing file is baselined to its current count (routine history
# is skipped — it is covered by the `aiurdev watch` tick). The one exception is
# the latest unresolved Executor decision attention, which is replayed so a
# watcher restart cannot hide an unanswered question.
#
# Tune with env vars:
#   AIUR_ALERT_POLL            (default 2)    — seconds between scans
#   AIUR_ALERT_WATCH_ITERS     (default 0)    — stop after N scans (0 = forever; for tests)
#   AIUR_ALERT_RELAY_BACKLOG   (default 0)    — 1 = also emit alerts already present at startup
#   AIUR_ALERT_NEEDS_ATTENTION (default 0)    — 1 = relay only needs_attention:true alerts
#   AIUR_ALERT_DISABLE_JQ       (default 0)    — 1 = force the portable jq-less path (tests)
#   AIUR_OPERATOR_SURFACES      (default empty) — comma list: claude,codex,remote-control
#   AIUR_ALERT_NOTIFY_CLAUDE_COMMAND / AIUR_ALERT_NOTIFY_CODEX_COMMAND /
#   AIUR_ALERT_NOTIFY_RC_COMMAND — trusted commands that receive each decision
#     escalation as JSON on stdin; Codex falls back to AIUR_ALERT_NOTIFY_FALLBACK_COMMAND.
#
# Usage: watch-alerts.sh [path/to/config]
#   Defaults to ./.aiur/config.
set -euo pipefail

config="${1:-}"
if [ -z "$config" ]; then
  config=".aiur/config"
fi
if [[ "$(basename "$config")" == *.aiurconfig ]]; then
  if [ "$(basename "$config")" = ".aiurconfig" ]; then
    canonical="$(dirname "$config")/.aiur/config"
  else
    canonical="${config%.aiurconfig}.yaml"
  fi
  echo "$config is no longer supported; move it to $canonical. Keep relative prompt_file and hooks_file paths valid from the new config directory." >&2
  exit 1
fi
poll="${AIUR_ALERT_POLL:-2}"
max_iters="${AIUR_ALERT_WATCH_ITERS:-0}"
relay_backlog="${AIUR_ALERT_RELAY_BACKLOG:-0}"
need_only="${AIUR_ALERT_NEEDS_ATTENTION:-0}"
operator_surfaces="${AIUR_OPERATOR_SURFACES:-}"

have_jq=0
if [ "${AIUR_ALERT_DISABLE_JQ:-0}" != "1" ] && command -v jq >/dev/null 2>&1; then
  have_jq=1
fi

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

# --- JSON helpers -----------------------------------------------------------
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\b'/\\b}"
  s="${s//$'\f'/\\f}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Extract one JSON-encoded string field without jq. Alert logs are compact Jason
# output; the regex keeps escaped characters inside the capture. Keeping the
# encoded contents intact lets the relay embed them directly in its own JSON,
# including quotes and control characters, without needing a second JSON parser
# on stock macOS hosts where jq is not installed.
json_string_field() {
  local line="$1" key="$2" encoded
  encoded="$(printf '%s' "$line" | sed -nE 's/.*"'"$key"'":"(([^"\\]|\\.)*)".*/\1/p')"
  [ -n "$encoded" ] || return 0
  printf '%s' "$encoded"
}

# Keep persisted NDJSON byte-for-byte compatible while presenting legacy
# decision copy with the current role name on every relay/notification surface.
normalize_legacy_role_line() {
  printf '%s' "$1" |
    sed -E 's/("(reason|message)"[[:space:]]*:[[:space:]]*")Operator decision /\1Executor decision /g'
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

alert_topic() {
  local line="$1"

  if [ "$have_jq" -eq 1 ]; then
    local topic
    topic="$(printf '%s' "$line" | jq -r '.topic // .name // ""' 2>/dev/null || true)"
    printf '%s\n' "$topic"
  else
    local topic
    topic="$(json_string_field "$line" "topic")"
    [ -n "$topic" ] || topic="$(json_string_field "$line" "name")"
    printf '%s\n' "$topic"
  fi
}

decision_lifecycle() {
  case "$1" in
    ticket.*.agent.attention.operator-decision)
      printf 'open|%s\n' "$1"
      ;;

    ticket.*.agent.attention.operator-decision.resolved)
      printf 'resolved|%s\n' "${1%.resolved}"
      ;;

    *)
      printf '|\n'
      ;;
  esac
}

decision_index() {
  local target="$1" key i=0
  for key in "${decision_keys[@]:-}"; do
    [ "$key" = "$target" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  printf '%s' -1
}

notify_surface() {
  local surface="$1" command="$2" line="$3"

  if [ -z "$command" ]; then
    printf '%s:unconfigured' "$surface"
  elif printf '%s\n' "$line" | sh -c "$command" >/dev/null 2>&1; then
    printf '%s:sent' "$surface"
  else
    printf '%s:failed' "$surface"
  fi
}

notify_operator_surfaces() {
  local line="$1" surface command result=""
  local old_ifs="$IFS"
  IFS=','

  for surface in $operator_surfaces; do
    case "$surface" in
      claude) command="${AIUR_ALERT_NOTIFY_CLAUDE_COMMAND:-}" ;;
      codex) command="${AIUR_ALERT_NOTIFY_CODEX_COMMAND:-${AIUR_ALERT_NOTIFY_FALLBACK_COMMAND:-}}" ;;
      remote-control) command="${AIUR_ALERT_NOTIFY_RC_COMMAND:-}" ;;
      *) command="" ;;
    esac

    [ -z "$surface" ] && continue
    [ -z "$result" ] || result="$result,"
    result="$result$(notify_surface "$surface" "$command" "$line")"
  done

  IFS="$old_ifs"
  [ -n "$result" ] || result="no-active-surface"
  printf '%s' "$result"
}

replay_open_decisions() {
  local snapshot="$1" agent="$2" line topic lifecycle state key idx
  local decision_keys=() decision_lines=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    topic="$(alert_topic "$line")"
    lifecycle="$(decision_lifecycle "$topic")"
    state="${lifecycle%%|*}"
    key="${lifecycle#*|}"

    case "$state" in
      open)
        idx="$(decision_index "$key")"
        if [ "$idx" -lt 0 ]; then
          decision_keys+=("$key")
          decision_lines+=("$line")
        else
          decision_lines[$idx]="$line"
        fi
        ;;

      resolved)
        idx="$(decision_index "$key")"
        [ "$idx" -lt 0 ] || decision_lines[$idx]=""
        ;;
    esac
  done <<< "$snapshot"

  for line in "${decision_lines[@]:-}"; do
    [ -z "$line" ] || emit_alert_line "$line" "$agent"
  done
}

# Map one raw alert ndjson line to the structured output line; honour the
# needs_attention-only Phase-2 filter. Mirrors the alert feed's field handling
# (kept in sync deliberately) and adds the timestamp.
emit_alert_line() {
  local line agent="$2"
  line="$(normalize_legacy_role_line "$1")"
  local ts msg name reason severity need src_ticket tkt operator_decision decision_state decision_key notification_results

  if [ "$have_jq" -eq 1 ]; then
    local parsed
    parsed="$(printf '%s' "$line" | jq -r 'select(.event=="alert") | [(.timestamp // ""), (.message // ""), (.topic // .name // ""), (.reason // ""), (.severity // "info"), (if .needs_attention == true then "true" else "false" end), (.source_ticket_id // "")] | join("\u001f")' 2>/dev/null || true)"
    [ -n "$parsed" ] || return 0
    IFS=$'\x1f' read -r ts msg name reason severity need src_ticket <<<"$parsed"
  else
    name="$(json_string_field "$line" "topic")"
    [ -n "$name" ] || name="$(json_string_field "$line" "name")"
    [ -n "$name" ] || return 0
    ts="$(json_string_field "$line" "timestamp")"
    msg="$(json_string_field "$line" "message")"
    reason="$(json_string_field "$line" "reason")"
    severity="$(json_string_field "$line" "severity")"
    src_ticket="$(json_string_field "$line" "source_ticket_id")"
    if printf '%s' "$line" | grep -q '"needs_attention":true'; then need="true"; else need="false"; fi
  fi

  tkt="$src_ticket"
  [ -n "$tkt" ] || tkt="$(printf '%s' "$name" | sed -n 's/^ticket\.\([^.]*\)\..*/\1/p')"
  [ -n "$tkt" ] || tkt="$agent"
  [ -n "$reason" ] || reason="$msg"
  [ -n "$reason" ] || reason="${name##*.}"
  [ -n "$severity" ] || severity="info"

  lifecycle="$(decision_lifecycle "$name")"
  decision_state="${lifecycle%%|*}"
  decision_key="${lifecycle#*|}"
  if [ -n "$decision_state" ]; then operator_decision=true; else operator_decision=false; fi

  [ "$need_only" != "1" ] || [ "$need" = "true" ] || [ "$decision_state" = "resolved" ] || return 0

  notification_results="not-applicable"
  if [ "$decision_state" = "open" ]; then
    notification_results="$(notify_operator_surfaces "$line")"
  fi

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
      --arg decision_state "$decision_state" \
      --arg decision_key "$decision_key" \
      --arg notification_results "$notification_results" \
      --argjson needs_attention "$need" \
      --argjson operator_decision "$operator_decision" \
      '{timestamp:$timestamp,ticket:$ticket,source_ticket_id:$source_ticket_id,agent:$agent,reason:$reason,severity:$severity,topic:$topic,name:$name,needs_attention:$needs_attention,operator_decision:$operator_decision,decision_state:$decision_state,decision_key:$decision_key,notification_results:$notification_results}'
  else
    printf '{"timestamp":"%s","ticket":"%s","source_ticket_id":"%s","agent":"%s","reason":"%s","severity":"%s","topic":"%s","name":"%s","needs_attention":%s,"operator_decision":%s,"decision_state":"%s","decision_key":"%s","notification_results":"%s"}\n' \
      "$ts" "$tkt" "$tkt" "$(json_escape "$agent")" "$reason" "$severity" \
      "$name" "$name" "$need" "$operator_decision" \
      "$(json_escape "$decision_state")" "$(json_escape "$decision_key")" "$(json_escape "$notification_results")"
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
        # First time we see this file. Baseline routine history, but replay the
        # latest unresolved decision attention so a monitor restart immediately
        # restores its durable Decisions entry and notification fan-out. A later
        # `.resolved` record suppresses that replay. New files discovered after
        # startup and explicit backlog mode still relay every alert as normal.
        if [ "$first_scan" -eq 1 ] && [ "$relay_backlog" != "1" ]; then
          replay_open_decisions "$snapshot" "$id"
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
