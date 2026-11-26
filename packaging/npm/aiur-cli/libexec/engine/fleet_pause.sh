# `aiur pause|resume --all-gateways`: record one fleet.pause change in the daemon (which pushes it
# to the shared store), then deliver the same change directly to every registry peer that has a url.
# The store is the durable path; the direct call only makes a reachable peer stop now. Sourced after
# remote_all.sh.

cmd_fleet_pause() {
  local command="$1" as="" expression rpc_status=0 err_file line store encoded result_dir peer_expr
  local records name url index=0 status label reason unknown=0 verb_now verb_later
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --as)
        [ "$#" -ge 2 ] && [[ "$2" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "aiur: --as expects an executor id" >&2; exit 64; }
        as="$2"
        shift 2
        ;;
      *) echo "aiur: --all-gateways is its own command (only --as <id> may accompany it)" >&2; exit 64 ;;
    esac
  done
  [ -z "${AIUR_REMOTE_INSTANCE:-}" ] || { echo "aiur: --all-gateways is its own command; it cannot be combined with ${AIUR_REMOTE_SELECTOR_FLAG:---instance}" >&2; exit 64; }

  expression="Aiur.AgentControlCLI.${command}_fleet()"
  [ -z "$as" ] || expression="Aiur.AgentControlCLI.${command}_fleet(as: \"$as\")"
  if [ "$command" = pause ]; then verb_now="paused now"; verb_later="will pause on reconnect"; else verb_now="resumed now"; verb_later="will resume on reconnect"; fi

  err_file="$(mktemp "${TMPDIR:-/tmp}/aiur-fleet-pause.XXXXXX")" || return 69
  run_control_rpc "$expression" 2>"$err_file" || rpc_status=$?
  if [ "$rpc_status" -ne 0 ]; then
    grep -v '^AIUR_FLEET_CHANGE ' "$err_file" >&2 || true
    rm -f "$err_file"
    return "$rpc_status"
  fi
  rm -f "$err_file"

  printf '%s\n' "$AIUR_CONTROL_RPC_OUTPUT" | grep -v -e '^AIUR_FLEET_CHANGE ' -e '^__AIUR_CONTROL_' || true
  line="$(printf '%s\n' "$AIUR_CONTROL_RPC_OUTPUT" | sed -n 's/^AIUR_FLEET_CHANGE //p' | head -1)"
  store="${line%% *}"
  encoded="${line#* }"
  [ -n "$line" ] && [ "$store" != "$encoded" ] || { echo "aiur: the daemon returned no fleet change to deliver" >&2; return 69; }

  peer_expr="Aiur.AgentControlCLI.apply_fleet_pause_change(Base.decode64!(\"$encoded\"))"
  records="$(load_remote_instance '*' 2>/dev/null)" || records=""
  result_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-fleet-pause-peers.XXXXXX")" || return 69
  chmod 700 "$result_dir"
  AIUR_REMOTE_ALL_MAX_SCOPE=write
  export AIUR_REMOTE_ALL_MAX_SCOPE

  local -a names=() urls=()
  while IFS=$'\t' read -r name url; do
    [ -n "$name" ] || continue
    names+=("$name")
    urls+=("$url")
    [ -z "$url" ] || run_remote_all_instance "$index" "$name" "$peer_expr" "$result_dir" &
    index=$((index + 1))
  done <<<"$records"
  wait

  for ((index = 0; index < ${#names[@]}; index++)); do
    name="${names[index]}"
    status="" reason=""
    if [ -n "${urls[index]}" ]; then
      status="$(cat "$result_dir/$index.status" 2>/dev/null || echo 1)"
      reason="$(grep -v '^$' "$result_dir/$index.error" 2>/dev/null | head -1 || true)"
    else
      reason="no url in the registry"
    fi
    if [ "$status" = 0 ] && grep -qE '^(applied|duplicate)$' "$result_dir/$index.output"; then
      label="$verb_now"
    elif [ "$status" = 0 ] && grep -q '^held$' "$result_dir/$index.output"; then
      label="held (clock skew)"
    elif [ "$store" = stored ]; then
      label="$verb_later (direct call: ${reason:-failed})"
    else
      label="unknown (retry when the store is reachable)"
      unknown=1
    fi
    printf '%s: %s\n' "$name" "$label"
  done
  rm -rf "$result_dir"

  [ "$unknown" -eq 0 ] || return 69
}
