# `aiur build-orders` — read the dashboard Build Order projection without a
# second GitHub or API derivation. A root selector switches from catalog to the
# selected-root graph view.
cmd_build_orders() {
  local json=0 root="" arg

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=1 ;;
      -*) echo "aiur: build-orders received an unknown option: $arg" >&2; exit 64 ;;
      *)
        if [ -n "$root" ]; then
          echo "aiur: build-orders accepts at most one root" >&2
          exit 64
        fi
        root="$arg"
        ;;
    esac
    shift
  done

  local opts=""
  [ "$json" -eq 1 ] && opts="json: true"

  if [ -n "$root" ]; then
    local encoded
    encoded="$(printf '%s' "$root" | base64 | tr -d '\n')"
    [ -n "$opts" ] && opts="$opts, "
    opts="${opts}root: Base.decode64!(\"$encoded\")"
  fi

  run_control_rpc "Aiur.AgentControlCLI.run_command(\"build-orders\", Aiur.BuildOrdersCLI, [$opts])"
}

register_control_command \
  "build-orders" \
  "aiur build-orders [<root>] [--json]  show the Build Order catalog or one root" \
  "cmd_build_orders"
