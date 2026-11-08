# Shared launcher `gateway` namespace parser. Sourced by aiur-engine.sh.
# permissions, grant, revoke and trust edit the receiving gateway's own registry grants; they never go over --gateway.
gateway_usage_error() { echo "aiur: $*" >&2; exit 64; }
gateway_rpc_string() { printf 'Base.decode64!("%s")' "$(encode_control_value "$1")"; }

# Called before the remote allowlist check: a grant change aimed at another gateway is refused here, exit 64.
ensure_gateway_grants_local() {
  [ "${1:-}" = gateway ] || return 0
  case "${2:-}" in
    grant | revoke | trust) echo 'aiur: grant changes are local to the receiving gateway' >&2; return 64 ;;
  esac
}

# Reads `agents --json` from the named entry (or every entry) in parallel through the remote_all worker, which
# resolves tokens and pins. Prints [{name, status, output}] for Aiur.Gateway.Status; a failed entry keeps its exit status.
gateway_collect() {
  local peer="$1" records name _url result_dir runtime index=0 pid
  local -a names=() pids=()
  if [ -n "$peer" ]; then
    [[ "$peer" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || gateway_usage_error "invalid gateway name '$peer'"
    load_remote_instance "$peer" || exit $?
    records="$(printf '%s\t%s' "$peer" "$AIUR_REMOTE_URL")"
  else
    records="$(load_remote_instance '*')" || exit $?
  fi
  runtime="$(remote_js_runtime)"
  [ -n "$runtime" ] || { echo "aiur: gateway list and status require Node.js" >&2; exit 69; }
  result_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-gateway-status.XXXXXX")" || exit 69
  chmod 700 "$result_dir"
  AIUR_CONTROL_RPC_TIMEOUT_SECONDS="${AIUR_GATEWAY_TIMEOUT_SECONDS:-5}"
  AIUR_CONTROL_COMMAND=agents
  while IFS=$'\t' read -r name _url; do
    [ -n "$name" ] || continue
    names+=("$name")
    (run_remote_all_instance "$index" "$name" 'Aiur.Handoff.CLI.agents()' "$result_dir") &
    pids+=("$!")
    index=$((index + 1))
  done <<<"$records"
  for pid in "${pids[@]+"${pids[@]}"}"; do wait "$pid" || true; done
  "$runtime" -e '
    const fs = require("node:fs");
    const [dir, ...names] = process.argv.slice(1);
    const read = (file) => { try { return fs.readFileSync(file, "utf8"); } catch (_) { return ""; } };
    process.stdout.write(JSON.stringify(names.map((name, i) => {
      const status = Number(read(`${dir}/${i}.status`).trim());
      return { name, status: Number.isInteger(status) && read(`${dir}/${i}.status`).trim() !== "" ? status : 69, output: read(`${dir}/${i}.output`) };
    })));
  ' "$result_dir" "${names[@]+"${names[@]}"}"
  rm -rf -- "$result_dir"
}

cmd_gateway() {
  local verb="${1:-}" peer="" port="" categories="" json=0 full=0 arg opts item data list=""
  [ "$#" -gt 0 ] && shift
  case "$verb" in
    permissions | grant | revoke | trust | discover | list | status) ;;
    *) gateway_usage_error 'gateway requires permissions, grant, revoke, trust, discover, list or status' ;;
  esac
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) case "$verb" in permissions | discover | list | status) ;; *) gateway_usage_error '--json requires gateway permissions, discover, list or status' ;; esac; json=1 ;;
      --port) [ "$verb" = discover ] && [[ "${2:-}" =~ ^[0-9]{1,5}$ ]] || gateway_usage_error '--port requires gateway discover and a number'; port="$2"; shift ;;
      --full) [ "$verb" = trust ] || gateway_usage_error '--full requires gateway trust'; full=1 ;;
      -*) gateway_usage_error "unknown gateway option $arg" ;;
      *)
        if [ -z "$peer" ]; then peer="$arg"
        elif [ "$verb" = grant ] || [ "$verb" = revoke ]; then categories="${categories:+$categories,}$arg"
        else gateway_usage_error "unexpected argument $arg"; fi ;;
    esac
    shift
  done
  case "$verb" in
    grant) [ -n "$peer" ] && [ -n "$categories" ] || gateway_usage_error 'gateway grant requires a peer and categories' ;;
    revoke | trust | status) [ -n "$peer" ] || gateway_usage_error "gateway $verb requires a peer" ;;
    list) [ -z "$peer" ] || gateway_usage_error "unexpected argument $peer" ;;
  esac
  [ "$verb" != trust ] || [ "$full" -eq 1 ] || gateway_usage_error 'gateway trust requires --full'
  opts=""
  case "$verb" in
    list | status)
      data="$(gateway_collect "$peer")" || return $?
      opts="data: $(gateway_rpc_string "$data")"
      ;;
  esac
  [ -n "$peer" ] && opts="${opts:+$opts, }peer: $(gateway_rpc_string "$peer")"
  if [ -n "$categories" ]; then
    IFS=',' read -r -a items <<<"$categories"
    for item in "${items[@]}"; do
      [[ "$item" =~ ^[a-z]{1,16}$ ]] || gateway_usage_error "invalid category '$item'"
      list="${list:+$list, }\"$item\""
    done
    opts="${opts:+$opts, }categories: [$list]"
  fi
  [ "$full" -eq 1 ] && opts="${opts:+$opts, }full: true"
  [ -n "$port" ] && opts="${opts:+$opts, }port: $port"
  [ "$json" -eq 1 ] && opts="${opts:+$opts, }json: true"
  run_control_rpc "Aiur.Gateway.Cli.$verb([$opts])"
}
