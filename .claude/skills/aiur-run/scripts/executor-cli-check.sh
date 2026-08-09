#!/usr/bin/env bash
set -euo pipefail

# Observe the operator-facing, read-only CLI surface for the run owning the
# current repository. The JSON output is intended to be embedded in the hourly
# retrospective rather than printed as a human report directly.

cli_command="${AIUR_CMD:-aiur}"
repo_root="${AIUR_EXECUTOR_REPO_ROOT:-${AIUR_REPO_ROOT:-}}"
timeout_seconds="${AIUR_META_CLI_TIMEOUT_SECONDS:-12}"
slow_ms="${AIUR_META_CLI_SLOW_MS:-8000}"
config_file="${AIUR_EXECUTOR_CONFIG:-}"
tmux_bin="${AIUR_EXECUTOR_TMUX:-tmux}"

if [ -z "$repo_root" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "$repo_root" ] || [ ! -d "$repo_root" ]; then
  printf 'AIUR_EXECUTOR_REPO_ROOT must name the repository that owns the daemon\n' >&2
  exit 64
fi
if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'AIUR_META_CLI_TIMEOUT_SECONDS must be a positive integer\n' >&2
  exit 64
fi
if [[ ! "$slow_ms" =~ ^[1-9][0-9]*$ ]]; then
  printf 'AIUR_META_CLI_SLOW_MS must be a positive integer\n' >&2
  exit 64
fi
if [ -z "$config_file" ]; then
  config_file="$repo_root/.aiur/config"
fi

cli_parts=()
read -r -a cli_parts <<< "$cli_command"
[ "${#cli_parts[@]}" -gt 0 ] || {
  printf 'AIUR_CMD must name the Aiur CLI command\n' >&2
  exit 64
}

now_ms() {
  local value
  value="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

json_lines() {
  local file="$1"
  if [ -s "$file" ]; then
    sed -n '1,5p' "$file" | jq -Rsc 'split("\n") | map(select(length > 0))'
  else
    printf '[]\n'
  fi
}

run_cli() {
  local name="$1" stdout_file="$2" stderr_file="$3" pid started now status timed_out=0
  started="$(now_ms)"
  (
    AIUR_REPO_ROOT="$repo_root" "${cli_parts[@]}" "$name" >"$stdout_file" 2>"$stderr_file"
  ) &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    now="$(now_ms)"
    if [ $((now - started)) -ge $((timeout_seconds * 1000)) ]; then
      timed_out=1
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.1
      kill -KILL "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.05
  done

  if wait "$pid"; then
    status=0
  else
    status=$?
  fi
  now="$(now_ms)"
  printf '%s\n' "$started" "$now" "$status" "$timed_out"
}

well_formed() {
  local name="$1" stdout_file="$2"
  case "$name" in
    status)
      grep -q '^ISSUE STATE' "$stdout_file" && grep -q '^AGENTS ' "$stdout_file"
      ;;
    agents)
      grep -q '^ISSUE  STATE      RUNTIME  ACTIVITY' "$stdout_file"
      ;;
    alerts)
      [ -s "$stdout_file" ] || return 1
      jq -es 'all(type == "object")' "$stdout_file" >/dev/null
      ;;
  esac
}

finding_for() {
  local name="$1" answered="$2" non_empty="$3" well_formed_value="$4" timed_out="$5" elapsed_ms="$6" exit_code="$7"
  if [ "$timed_out" -eq 1 ]; then
    jq -nc --arg name "$name" --argjson elapsed_ms "$elapsed_ms" \
      '{kind:"cli",command:$name,reason:"timed_out",elapsed_ms:$elapsed_ms}'
  elif [ "$answered" -eq 0 ]; then
    jq -nc --arg name "$name" --argjson elapsed_ms "$elapsed_ms" \
      '{kind:"cli",command:$name,reason:"did_not_answer",elapsed_ms:$elapsed_ms}'
  elif [ "$non_empty" -eq 0 ]; then
    jq -nc --arg name "$name" --argjson elapsed_ms "$elapsed_ms" \
      '{kind:"cli",command:$name,reason:"empty_output",elapsed_ms:$elapsed_ms}'
  elif [ "$well_formed_value" -eq 0 ]; then
    jq -nc --arg name "$name" --argjson elapsed_ms "$elapsed_ms" \
      '{kind:"cli",command:$name,reason:"malformed_output",elapsed_ms:$elapsed_ms}'
  elif [ "$exit_code" -ne 0 ]; then
    jq -nc --arg name "$name" --argjson elapsed_ms "$elapsed_ms" --argjson exit_code "$exit_code" \
      '{kind:"cli",command:$name,reason:"nonzero_exit",elapsed_ms:$elapsed_ms,exit_code:$exit_code}'
  elif [ "$elapsed_ms" -ge "$slow_ms" ]; then
    jq -nc --arg name "$name" --argjson elapsed_ms "$elapsed_ms" --argjson threshold_ms "$slow_ms" \
      '{kind:"cli",command:$name,reason:"slow_response",elapsed_ms:$elapsed_ms,slow_threshold_ms:$threshold_ms}'
  else
    printf 'null\n'
  fi
}

config_value() {
  local key="$1"
  [ -r "$config_file" ] || return 0
  case "$key" in
    pre_warmed_sessions)
      awk '$1 == "pre_warmed_sessions:" {print $2; exit}' "$config_file"
      ;;
    max_concurrent_agents)
      awk '$1 == "max_concurrent_agents:" {print $2; exit}' "$config_file"
      ;;
  esac
}

read_identity() {
  local identity_file="$1"
  if [ -n "${AIUR_TMUX_SOCKET:-}" ] && [ -n "${AIUR_TMUX_SESSION:-}" ]; then
    return 0
  fi

  local identity_output
  identity_output="$(AIUR_REPO_ROOT="$repo_root" "${cli_parts[@]}" __identity 2>/dev/null || true)"
  while IFS='=' read -r key value; do
    case "$key" in
      AIUR_SESSION_PREFIX|AIUR_INSTANCE_KEY|AIUR_RELEASE_NODE) printf '%s\n' "$key=$value" >> "$identity_file" ;;
    esac
  done <<< "$identity_output"
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-cli-check.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

commands_json='[]'
findings_json='[]'
for name in status agents alerts; do
  stdout_file="$tmp_dir/$name.out"
  stderr_file="$tmp_dir/$name.err"
  mapfile -t run_result < <(run_cli "$name" "$stdout_file" "$stderr_file")
  started="${run_result[0]}"
  finished="${run_result[1]}"
  exit_code="${run_result[2]}"
  timed_out="${run_result[3]}"
  elapsed_ms=$((finished - started))
  if [ "$timed_out" -eq 1 ] || [ "$exit_code" -eq 124 ]; then
    answered=0
  else
    answered=1
  fi
  if [ -s "$stdout_file" ] || [ -s "$stderr_file" ]; then non_empty=1; else non_empty=0; fi
  if well_formed "$name" "$stdout_file"; then well_formed_value=1; else well_formed_value=0; fi
  first_lines="$(json_lines "$stdout_file")"
  [ "$first_lines" != '[]' ] || first_lines="$(json_lines "$stderr_file")"
  finding="$(finding_for "$name" "$answered" "$non_empty" "$well_formed_value" "$timed_out" "$elapsed_ms" "$exit_code")"

  item="$(jq -nc --arg command "$name" --argjson answered "$answered" \
    --argjson timed_out "$timed_out" --argjson elapsed_ms "$elapsed_ms" \
    --argjson exit_code "$exit_code" --argjson non_empty "$non_empty" \
    --argjson well_formed "$well_formed_value" --argjson first_lines "$first_lines" \
    --argjson finding "$finding" \
    '{command:$command,answered:($answered == 1),timed_out:($timed_out == 1),elapsed_ms:$elapsed_ms,exit_code:$exit_code,non_empty:($non_empty == 1),well_formed:($well_formed == 1),first_lines:$first_lines,finding:$finding}')"
  commands_json="$(jq --argjson item "$item" '. + [$item]' <<< "$commands_json")"
  [ "$finding" = 'null' ] || findings_json="$(jq --argjson finding "$finding" '. + [$finding]' <<< "$findings_json")"
done

identity_file="$tmp_dir/identity"
: > "$identity_file"
read_identity "$identity_file"
session_prefix="$(awk -F= '$1 == "AIUR_SESSION_PREFIX" {print $2}' "$identity_file")"
instance_key="$(awk -F= '$1 == "AIUR_INSTANCE_KEY" {print $2}' "$identity_file")"
release_node="$(awk -F= '$1 == "AIUR_RELEASE_NODE" {print $2}' "$identity_file")"
session_prefix="${AIUR_SESSION_PREFIX:-${session_prefix:-aiur}}"
instance_key="${AIUR_INSTANCE_KEY:-$instance_key}"
release_node="${AIUR_RELEASE_NODE:-$release_node}"
user_name="${USER:-$(id -un)}"
socket="${AIUR_TMUX_SOCKET:-${session_prefix}-${user_name}${instance_key:+-$instance_key}}"
session="${AIUR_TMUX_SESSION:-${socket}-default}"
pre_warmed_sessions="$(config_value pre_warmed_sessions)"
live_agent_cap="$(config_value max_concurrent_agents)"
pane_count=""
session_present=0
if command -v "$tmux_bin" >/dev/null 2>&1 && "$tmux_bin" -L "$socket" has-session -t "$session" 2>/dev/null; then
  session_present=1
  pane_count="$("$tmux_bin" -L "$socket" list-panes -a -t "$session" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')"
fi

if [ "$session_present" -eq 0 ]; then
  pane_finding="$(jq -nc --arg socket "$socket" --arg session "$session" \
    '{kind:"pane_surface",reason:"session_unavailable",socket:$socket,session:$session}')"
  findings_json="$(jq --argjson finding "$pane_finding" '. + [$finding]' <<< "$findings_json")"
fi

jq -nc --arg checked_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg repo_root "$repo_root" --arg release_node "$release_node" --arg socket "$socket" --arg session "$session" \
  --argjson commands "$commands_json" --argjson findings "$findings_json" \
  --argjson session_present "$session_present" --argjson pane_count "${pane_count:-null}" \
  --argjson pre_warmed_sessions "${pre_warmed_sessions:-null}" --argjson live_agent_cap "${live_agent_cap:-null}" \
  '{checked_at:$checked_at,target:{repo_root:$repo_root,release_node:$release_node},commands:$commands,pane_surface:{session:$session,socket:$socket,session_present:($session_present == 1),pane_count:$pane_count,pre_warmed_sessions:$pre_warmed_sessions,live_agent_cap:$live_agent_cap},findings:$findings}'
