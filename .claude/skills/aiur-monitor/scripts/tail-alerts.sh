#!/usr/bin/env bash
#
# Tail aiur ALERT events out of every ACTIVE agent's structured NDJSON log, so
# the operator who just heard a random alert sound gets the context to act on it
# (which ticket, which agent, why, and whether it needs a human RIGHT NOW).
#
# aiur emits ALERTs as events AND appends them to each workspace's
# logs/agent.ndjson, one JSON object per line:
#   {"event":"alert","message":"Agent paused","name":"ticket.43.agent.paused",...}
# The alert TOPIC is `.name` (e.g. ticket.<id>.agent.paused / system.<...>).
# There is no CLI to tail these and no "needs operator" flag — that verdict is
# DERIVED here, in shell, from the topic name (no model in the loop).
#
# Output: a DAEMON header (same shape as tail-agents.sh) then one structured
# line per alert, OLDEST first / NEWEST last, ready to relay:
#   {"ticket":"43","agent":"43","reason":"Agent paused","name":"ticket.43.agent.paused","needs_attention":true}
#
# This is a read-only sibling of tail-agents.sh: it reuses the same root
# enumeration (config workspace.root + ~/.aiur/workspaces, deduped), the same
# recency/active-window logic, the same seen_logs cross-root dedupe, and the
# same read-only daemon probes. It never attaches to tmux or the running node.
#
# Tune with env vars:
#   AIUR_ACTIVE_WINDOW_MIN  (default 15)  — how recent (by ndjson mtime) counts as active
#   AIUR_INCLUDE_STALE=1                  — include stale agents too (e.g. post-run review)
#   AIUR_ALERT_TAIL                       — cap alerts emitted per agent (default: all)
#
# Usage: tail-alerts.sh [path/to/config]
#   Defaults to ./.aiur/config (current layout), falling back to ./.aiurconfig (legacy).
set -euo pipefail

config="${1:-}"
if [ -z "$config" ]; then
  if [ -f .aiur/config ]; then config=".aiur/config"
  elif [ -f .aiurconfig ]; then config=".aiurconfig"
  else config=".aiur/config"; fi
fi
window_min="${AIUR_ACTIVE_WINDOW_MIN:-15}"
include_stale="${AIUR_INCLUDE_STALE:-0}"
alert_tail="${AIUR_ALERT_TAIL:-0}"   # 0 = no cap

# Topics that mean "an operator should look NOW". Matched case-insensitively as
# substrings of the alert topic (.name). Derived verdict — no model.
attention_keywords="human-review input_required paused thrash retry_exhausted tokens_exhausted"

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

# mtime in epoch seconds, portable across GNU (stat -c) and macOS (stat -f).
# GNU first: on GNU coreutils `-f` means --file-system (NOT a format string),
# so a macOS-first probe silently succeeds with filesystem garbage on Linux.
mtime_epoch() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

now="$(date +%s)"

# --- Resolve candidate workspace roots ------------------------------------
# config_root is the static default from `.aiur/config`; it may be empty or
# stale. The home root (`~/.aiur/workspaces`) is where a live instance actually
# materializes per-issue workspaces, so it's always scanned.
config_root=""
if [ -f "$config" ]; then
  config_root="$(awk '
    /^[^[:space:]#]/ { in_ws = ($1 == "workspace:") }
    in_ws && $1 == "root:" { print $2; exit }
  ' "$config")"
  config_root="${config_root/#\~/$HOME}"
fi

home_root="$HOME/.aiur/workspaces"

# Deduped, existing roots to scan. Keep config_root first so it wins labeling.
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

# --- Daemon health probe ---------------------------------------------------
# A live aiur runs the BEAM from a `rel/aiur` release. Read-only probe, same as
# tail-agents.sh, so the header can say whether the node is still up.
node_up=no
if pgrep -f 'rel/aiur/.*beam' >/dev/null 2>&1; then
  node_up=yes
fi

# Track the most recent activity across everything, so a downed node still
# yields a "last activity X ago" rather than silence.
latest_mtime=0
note_mtime() {
  local m="$1"
  [ -n "$m" ] || return 0
  # Guard the comparison's exit code: a "not greater" result returns 1, which
  # under `set -e` would abort the whole run mid-scan. Always return 0.
  if [ "$m" -gt "$latest_mtime" ]; then latest_mtime="$m"; fi
  return 0
}

# --- needs_attention verdict (shell, no model) -----------------------------
# true iff the topic contains any attention keyword on a SEGMENT boundary,
# case-insensitively. The boundary requirement is load-bearing: topic segments
# are split by `.`/`_`/`-`, and a naive substring test flags `agent.unpaused`
# (the all-clear) as needing attention because it ends in `paused`. So a keyword
# must sit at start-of-string or right after a non-alphanumeric delimiter.
needs_attention() {
  local name_lc kw before
  name_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for kw in $attention_keywords; do
    case "$name_lc" in
      "$kw"*) printf 'true'; return 0 ;;          # at start
      *[!a-z0-9]"$kw"*)                            # after a delimiter
        # The case above also matches mid-word if the char before kw is the
        # delimiter — which is exactly the boundary we want. Guard the rare
        # case where kw embeds in a longer alnum run by re-checking the char
        # immediately before the match is a delimiter.
        before="${name_lc%%"$kw"*}"
        case "${before: -1}" in
          [!a-z0-9]) printf 'true'; return 0 ;;
        esac
        ;;
    esac
  done
  printf 'false'
}

# --- JSON helpers ----------------------------------------------------------
# Without jq we still must emit valid JSON; escape the bare minimum (\ and ").
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# --- Collect alerts across all roots ---------------------------------------
# Buffer alert lines so the DAEMON header (which needs the aggregate "last
# activity") prints before them.
alert_lines=""
found_agents=0
alert_count=0
seen_logs=""        # |-delimited absolute paths, for cross-root dedupe

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

    m="$(mtime_epoch "$abs")"; m="${m:-0}"
    note_mtime "$m"
    age_min=$(( (now - m) / 60 ))
    if [ "$include_stale" != "1" ] && [ "$age_min" -gt "$window_min" ]; then
      continue
    fi

    found_agents=$((found_agents + 1))

    # Pull alert events for THIS agent into a small temp buffer, oldest first.
    # grep prefilter first so jq only ever sees alert lines (cheap on huge logs).
    agent_alerts=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue

      if [ "$have_jq" -eq 1 ]; then
        # One jq pass yields message<TAB>name; non-alert/garbage lines are dropped.
        parsed="$(printf '%s' "$line" | jq -r 'select(.event=="alert") | [(.message // ""), (.name // "")] | @tsv' 2>/dev/null || true)"
        [ -n "$parsed" ] || continue
        msg="${parsed%%$'\t'*}"
        name="${parsed#*$'\t'}"
      else
        # jq-less fallback: scrape "name":"..." and "message":"..." from the raw
        # line. Good enough for the flat alert objects aiur writes.
        name="$(printf '%s' "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
        [ -n "$name" ] || continue
        msg="$(printf '%s' "$line" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')"
      fi

      # ticket id: parse `ticket.<id>.` from the topic, else fall back to the
      # workspace dir name (== ticket id == agent id for per-issue workspaces).
      tkt="$(printf '%s' "$name" | sed -n 's/^ticket\.\([^.]*\)\..*/\1/p')"
      [ -n "$tkt" ] || tkt="$id"

      # reason: prefer the human message; else the topic's last segment.
      reason="$msg"
      [ -n "$reason" ] || reason="${name##*.}"

      need="$(needs_attention "$name")"

      agent_alerts="${agent_alerts}{\"ticket\":\"$(json_escape "$tkt")\",\"agent\":\"$(json_escape "$id")\",\"reason\":\"$(json_escape "$reason")\",\"name\":\"$(json_escape "$name")\",\"needs_attention\":${need}}
"
    done < <(grep '"event":"alert"' "$abs" 2>/dev/null || true)

    [ -n "$agent_alerts" ] || continue

    # Optional per-agent cap: keep the NEWEST N (tail).
    if [ "$alert_tail" -gt 0 ]; then
      agent_alerts="$(printf '%s' "$agent_alerts" | tail -n "$alert_tail")
"
    fi

    n=$(printf '%s' "$agent_alerts" | grep -c '^{' || true)
    alert_count=$((alert_count + n))
    alert_lines="${alert_lines}${agent_alerts}"
  done < <(find "$root" -maxdepth 6 -type f -name agent.ndjson 2>/dev/null)
done

# --- Emit -------------------------------------------------------------------
roots_list=""
[ "${#roots[@]}" -gt 0 ] && roots_list="$(printf '%s ' "${roots[@]}")"
[ -n "$roots_list" ] || roots_list="(none existed) "

if [ "$latest_mtime" -gt 0 ]; then
  last_age=$(( (now - latest_mtime) / 60 ))
  last_activity="${last_age}m ago"
else
  last_activity="never (no logs seen)"
fi

echo "===== DAEMON node ${node_up} | last activity ${last_activity} | alerts ${alert_count} | roots ${roots_list}====="
if [ "$node_up" = "no" ] && [ "$latest_mtime" -gt 0 ]; then
  echo "daemon down: no aiur BEAM process; last activity ${last_activity}"
fi
echo

if [ "$alert_count" -gt 0 ]; then
  printf '%s' "$alert_lines"
else
  if [ "${#roots[@]}" -eq 0 ]; then
    echo "(no workspace roots exist yet — looked for config workspace.root and ${home_root})"
  elif [ "$found_agents" -eq 0 ]; then
    echo "(no active agents — no agent.ndjson modified in the last ${window_min}m under ${roots_list})"
  else
    echo "(no alerts in the ${found_agents} active agent log(s) under ${roots_list})"
  fi
fi
