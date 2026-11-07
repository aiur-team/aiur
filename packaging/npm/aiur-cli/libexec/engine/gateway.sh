# --gateway <name|label|id|all|local> selector. Sourced by aiur-engine.sh.
# Resolves to the same AIUR_REMOTE_INSTANCE path that --instance uses.

# Parses a leading --instance/--gateway (either form) from "$@"; sets
# AIUR_SELECTOR_SHIFT to the args consumed. Returns 64 on misuse.
parse_remote_selector() {
  local flag="" value="" shift_by=0
  AIUR_SELECTOR_SHIFT=0
  case "${1:-}" in
    --instance) flag=--instance; value="${2:-}"; shift_by=2 ;;
    --gateway) flag=--gateway; value="${2:-}"; shift_by=2 ;;
    --instance=*) flag=--instance; value="${1#*=}"; shift_by=1 ;;
    --gateway=*) flag=--gateway; value="${1#*=}"; shift_by=1 ;;
    *) return 0 ;;
  esac
  [ -n "$value" ] || { echo "aiur: $flag requires a name" >&2; return 64; }
  shift "$shift_by"
  case "${1:-}" in
    --instance | --instance=* | --gateway | --gateway=*)
      echo "aiur: use one of --gateway or --instance" >&2
      return 64
      ;;
  esac
  AIUR_SELECTOR_SHIFT="$shift_by"
  if [ "$flag" = --instance ]; then
    export AIUR_REMOTE_INSTANCE="$value"
    return 0
  fi
  export AIUR_REMOTE_SELECTOR_FLAG=--gateway
  resolve_gateway "$value"
}

resolve_gateway() {
  local selector="$1" file matches count
  case "$selector" in
    local) unset AIUR_REMOTE_INSTANCE; return 0 ;;
    all) export AIUR_REMOTE_INSTANCE=all; return 0 ;;
  esac
  file="$(remote_registry_path)"
  if [ ! -r "$file" ]; then
    echo "aiur: remote instance registry $AIUR_REMOTE_REGISTRY_DISPLAY is missing or unreadable" >&2
    return 64
  fi
  matches="$(AIUR_GATEWAY_SELECTOR="$selector" LC_ALL=C awk -f "$engine_dir/engine/registry.awk" -v target="@resolve" -v display="$AIUR_REMOTE_REGISTRY_DISPLAY" "$file")" || return $?
  count=0
  [ -z "$matches" ] || count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  case "$count" in
    0) echo "aiur: unknown gateway '$selector' in $AIUR_REMOTE_REGISTRY_DISPLAY" >&2; return 64 ;;
    1) export AIUR_REMOTE_INSTANCE="${matches%%$'\t'*}" ;;
    *)
      echo "aiur: gateway '$selector' is ambiguous in $AIUR_REMOTE_REGISTRY_DISPLAY; it matches:" >&2
      printf '%s\n' "$matches" | awk -F'\t' '{ print "  " $1 "  (" $2 ")" }' >&2
      echo "use the registry name with --instance, or the gateway id" >&2
      return 64
      ;;
  esac
}
