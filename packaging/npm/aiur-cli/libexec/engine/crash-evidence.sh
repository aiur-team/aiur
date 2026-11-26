# Crash evidence shared by the daemon run path and the BEAM's tmux pane.

aiur_enable_core_dumps() {
  local hard_core_limit
  hard_core_limit="$(ulimit -Hc 2>/dev/null || true)"
  if [ "$hard_core_limit" = unlimited ]; then
    ulimit -Sc unlimited 2>/dev/null || true
  elif [[ "$hard_core_limit" =~ ^[0-9]+$ ]]; then
    ulimit -Sc "$hard_core_limit" 2>/dev/null || true
  fi
}

aiur_prepare_dump_target() {
  local logs_root="$1" dump_path="$2" dump_probe=""
  mkdir -p "$logs_root/log" || die "cannot create Aiur run log directory: $logs_root/log"
  if [ -e "$dump_path" ]; then
    [ -f "$dump_path" ] && [ -w "$dump_path" ] || die "BEAM crash dump path is not a writable file: $dump_path"
  else
    mkdir -p "$(dirname "$dump_path")" || die "cannot create BEAM crash dump directory: $(dirname "$dump_path")"
    dump_probe="$(mktemp "${dump_path}.probe.XXXXXX")" || die "BEAM crash dump path is not writable: $dump_path"
    rm -f "$dump_probe"
  fi
}
