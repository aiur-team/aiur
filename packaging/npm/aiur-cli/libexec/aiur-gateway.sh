# Shared launcher `gateway` namespace parser. Sourced by aiur-engine.sh.
# permissions, grant, revoke and trust edit the receiving gateway's own registry grants; they never go over --gateway.
source "$(dirname "${BASH_SOURCE[0]}")/engine/gateway_enroll.sh"
gateway_usage_error() { echo "aiur: $*" >&2; exit 64; }
gateway_ttl_seconds() {
  local n="${1%[smhd]}"
  case "${1: -1}" in m) echo $((n * 60)) ;; h) echo $((n * 3600)) ;; d) echo $((n * 86400)) ;; *) echo "$n" ;; esac
}
gateway_rpc_string() { printf 'Base.decode64!("%s")' "$(encode_control_value "$1")"; }

# Called before the remote allowlist check: a grant change aimed at another gateway is refused here, exit 64.
ensure_gateway_grants_local() {
  [ "${1:-}" = gateway ] || return 0
  case "${2:-}" in
    grant | revoke | trust) echo 'aiur: grant changes are local to the receiving gateway' >&2; return 64 ;;
    invite | join | register | remove | rotate) echo "aiur: $2 is local to the gateway it changes" >&2; return 64 ;;
  esac
}

cmd_gateway() {
  local verb="${1:-}" peer="" port="" categories="" json=0 full=0 arg opts item list="" ttl="" url="" pin="" name="" token_file=""
  [ "$#" -gt 0 ] && shift
  case "$verb" in
    permissions | grant | revoke | trust | discover | invite | join | register | remove | rotate) ;;
    *) gateway_usage_error 'gateway requires permissions, grant, revoke, trust, discover, invite, join, register, remove or rotate' ;;
  esac
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) [ "$verb" = permissions ] || [ "$verb" = discover ] || gateway_usage_error '--json requires gateway permissions or discover'; json=1 ;;
      --port) [ "$verb" = discover ] && [[ "${2:-}" =~ ^[0-9]{1,5}$ ]] || gateway_usage_error '--port requires gateway discover and a number'; port="$2"; shift ;;
      --full) [ "$verb" = trust ] || gateway_usage_error '--full requires gateway trust'; full=1 ;;
      --grant) [ "$verb" = invite ] && [ -n "${2:-}" ] || gateway_usage_error '--grant requires gateway invite and a category list'; categories="$2"; shift ;;
      --ttl) [ "$verb" = invite ] && [[ "${2:-}" =~ ^[0-9]+[smhd]?$ ]] || gateway_usage_error '--ttl requires gateway invite and a duration such as 10m'; ttl="$2"; shift ;;
      --url) { [ "$verb" = invite ] || [ "$verb" = register ]; } && [ -n "${2:-}" ] || gateway_usage_error '--url requires gateway invite or register and a value'; url="$2"; shift ;;
      --tls-pin) { [ "$verb" = invite ] || [ "$verb" = register ]; } && [ -n "${2:-}" ] || gateway_usage_error '--tls-pin requires gateway invite or register and a value'; pin="$2"; shift ;;
      --name) [ "$verb" = join ] && [ -n "${2:-}" ] || gateway_usage_error '--name requires gateway join and a value'; name="$2"; shift ;;
      --token-file) [ "$verb" = register ] && [ -n "${2:-}" ] || gateway_usage_error '--token-file requires gateway register and a path'; token_file="$2"; shift ;;
      -*) gateway_usage_error "unknown gateway option $arg" ;;
      *)
        if [ -z "$peer" ]; then peer="$arg"
        elif [ "$verb" = grant ] || [ "$verb" = revoke ]; then categories="${categories:+$categories,}$arg"
        else gateway_usage_error "unexpected argument $arg"; fi ;;
    esac
    shift
  done
  case "$verb" in
    join) [ -n "$peer" ] && [ -n "$name" ] || gateway_usage_error 'gateway join requires an invite code and --name'; gateway_join "$peer" "$name"; return $? ;;
    register) gateway_register "$peer" "$url" "$token_file" "$pin"; return $? ;;
    remove | rotate) [ -n "$peer" ] || gateway_usage_error "gateway $verb requires a peer" ;;
  esac
  case "$verb" in
    grant) [ -n "$peer" ] && [ -n "$categories" ] || gateway_usage_error 'gateway grant requires a peer and categories' ;;
    revoke | trust) [ -n "$peer" ] || gateway_usage_error "gateway $verb requires a peer" ;;
  esac
  [ "$verb" != trust ] || [ "$full" -eq 1 ] || gateway_usage_error 'gateway trust requires --full'
  opts=""
  [ -n "$peer" ] && opts="peer: $(gateway_rpc_string "$peer")"
  if [ -n "$categories" ]; then
    IFS=',' read -r -a items <<<"$categories"
    for item in "${items[@]}"; do
      [[ "$item" =~ ^[a-z]{1,16}$ ]] || gateway_usage_error "invalid category '$item'"
      list="${list:+$list, }\"$item\""
    done
    opts="${opts:+$opts, }categories: [$list]"
  fi
  [ -z "$ttl" ] || opts="${opts:+$opts, }ttl: $(gateway_ttl_seconds "$ttl")"
  [ -z "$url" ] || opts="${opts:+$opts, }url: $(gateway_rpc_string "$url")"
  [ -z "$pin" ] || opts="${opts:+$opts, }tls_pin: $(gateway_rpc_string "$pin")"
  [ "$full" -eq 1 ] && opts="${opts:+$opts, }full: true"
  [ -n "$port" ] && opts="${opts:+$opts, }port: $port"
  [ "$json" -eq 1 ] && opts="${opts:+$opts, }json: true"
  run_control_rpc "Aiur.Gateway.Cli.$verb([$opts])"
}
