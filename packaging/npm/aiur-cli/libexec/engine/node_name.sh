# Node-name release checks used during restart. Sourced by aiur-engine.sh.

wait_for_node_name_release() {
  local node="$1" ticks="${2:-300}" tick
  for ((tick = 0; tick < ticks; tick++)); do
    local state
    state="$(probe_named_node_liveness "$node")"
    [ "$state" = "down" ] && return 0
    # A present epmd executable that cannot connect means the local epmd
    # daemon is absent; no node name can remain registered there.
    if [ "$state" = "unknown" ]; then
      local epmd found=0
      for epmd in "$release_dir"/erts-*/bin/epmd; do
        [ -x "$epmd" ] || continue
        found=1
        if ! ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}" "$epmd" -names >/dev/null 2>&1; then
          return 0
        fi
      done
      if [ "$found" -eq 0 ]; then
        echo "aiur: cannot verify node-name release because this release has no epmd binary; proceeding with startup retry handling" >&2
        return 0
      fi
    fi
    sleep 0.1
  done
  [ "$(probe_named_node_liveness "$node")" = "down" ]
}
