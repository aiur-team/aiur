# `aiur units` — read the dashboard Units catalog through its own projection,
# including non-running tickets in current-run membership.
cmd_units() {
  local scope="live" format="" json=0 arg condition condition_value condition_encoded conditions_literal=""
  local -a conditions=() condition_values=()
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --scope) [ "$#" -gt 1 ] || { echo "aiur: units --scope requires a value" >&2; exit 64; }; shift; scope="$1" ;;
      --scope=*) scope="${arg#--scope=}" ;;
      --condition) [ "$#" -gt 1 ] || { echo "aiur: units --condition requires a value" >&2; exit 64; }; shift; conditions+=("$1") ;;
      --condition=*) conditions+=("${arg#--condition=}") ;;
      --format) [ "$#" -gt 1 ] || { echo "aiur: units --format requires a value" >&2; exit 64; }; shift; format="$1" ;;
      --format=*) format="${arg#--format=}" ;;
      --json) json=1 ;;
      -*) echo "aiur: units received an unknown option: $arg" >&2; exit 64 ;;
      *) echo "aiur: units does not accept positional arguments" >&2; exit 64 ;;
    esac
    shift
  done

  for condition in "${conditions[@]+"${conditions[@]}"}"; do
    IFS=',' read -r -a condition_values <<< "$condition"
    for condition_value in "${condition_values[@]+"${condition_values[@]}"}"; do
      if [ -n "$conditions_literal" ]; then conditions_literal="$conditions_literal, "; fi
      condition_encoded="$(printf '%s' "$condition_value" | base64 | tr -d '\n')"
      conditions_literal="${conditions_literal}Base.decode64!(\"${condition_encoded}\")"
    done
  done

  local scope_encoded
  scope_encoded="$(printf '%s' "$scope" | base64 | tr -d '\n')"
  local opts="scope: Base.decode64!(\"$scope_encoded\")"
  [ -z "$conditions_literal" ] || opts="$opts, conditions: [$conditions_literal]"

  if [ -n "$format" ]; then
    local format_encoded
    format_encoded="$(printf '%s' "$format" | base64 | tr -d '\n')"
    opts="$opts, format: Base.decode64!(\"$format_encoded\")"
  fi

  [ "$json" -eq 1 ] && opts="$opts, json: true"
  run_control_rpc "Aiur.AgentControlCLI.run_command(\"units\", Aiur.UnitsCLI, [$opts])"
}

register_control_command \
  "units" \
  "aiur units [--scope live|unfinished|all|none] [--condition active|alert|paused|queued|finished]... [--format auto|table|records] [--json]" \
  "cmd_units"
