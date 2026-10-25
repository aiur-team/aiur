# Read-only fan-out for `aiur --instance all`. Sourced after remote.sh.

remote_all_has_arg() {
  local needle="$1" arg
  shift
  for arg in "$@"; do [ "$arg" != "$needle" ] || return 0; done
  return 1
}

ensure_remote_all_read_command() {
  local command="${1:-}" arg allowed=1 full=0
  shift 2>/dev/null || true

  AIUR_REMOTE_ALL_JSON=0
  for arg in "$@"; do [ "$arg" != "--json" ] || AIUR_REMOTE_ALL_JSON=1; done

  case "$command" in
    status | usage | agents | accounts | commands | units | build-orders | analytics | github-cost | capabilities | ticket-usage | github-usage | executor-subscriptions | executor-roster | executor-session)
      ;;
    message)
      [ "${1:-}" = "--status" ] || allowed=0
      ;;
    queue)
      case "${1:-}" in
        show) ;;
        order) [ "$#" -eq 1 ] || allowed=0 ;;
        *) allowed=0 ;;
      esac
      ;;
    epic)
      case "${1:-}" in show | list) ;; *) allowed=0 ;; esac
      ;;
    feature)
      [ "${1:-}" = "show" ] || allowed=0
      ;;
    experiments)
      case "${1:-}" in list | show | metrics | events | stats | analyze) ;; *) allowed=0 ;; esac
      ;;
    alerts)
      remote_all_has_arg ack "$@" && allowed=0
      ;;
    executor-sweep)
      remote_all_has_arg --apply "$@" && allowed=0
      ;;
    watch)
      for arg in "$@"; do
        case "$arg" in
          --full) full=1 ;;
          --changes) allowed=0 ;;
        esac
      done
      [ "$full" -eq 1 ] || allowed=0
      ;;
    *) allowed=0 ;;
  esac

  [ "$allowed" -eq 1 ] || {
    echo "aiur: --instance all is for read commands" >&2
    return 64
  }
}

run_remote_all_instance() {
  local index="$1" name="$2" expression="$3" result_dir="$4" status=0
  AIUR_REMOTE_INSTANCE="$name"
  AIUR_REMOTE_MAX_SCOPE=read
  AIUR_CONTROL_RPC_OUTPUT=""

  run_remote_rpc_with_timeout "$expression" 2>"$result_dir/$index.error" || status=$?
  printf '%s' "$status" >"$result_dir/$index.status"
  printf '%s' "${AIUR_CONTROL_RPC_OUTPUT:-}" >"$result_dir/$index.output"
  printf '%s' "${AIUR_REMOTE_URL:-}" >"$result_dir/$index.url"
}

render_remote_all_results() {
  local result_dir="$1" runtime
  shift
  runtime="$(remote_js_runtime)"
  [ -n "$runtime" ] || return 69

  "$runtime" -e '
    const fs = require("node:fs");
    const [dir, jsonMode, ...names] = process.argv.slice(1);
    const read = (path) => { try { return fs.readFileSync(path, "utf8"); } catch (_) { return ""; } };
    const codeFor = (status) => ({64: "refused", 69: "unreachable", 77: "permission_denied", 124: "timeout"})[status] || "failed";
    const detailFor = (index) => {
      const lines = read(`${dir}/${index}.error`).split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
      const named = lines.filter((line) => line.startsWith("aiur:"));
      return (named.length ? named : lines).map((line) => line.replace(/^aiur:\s*/, "")).join("; ") || "fan-out worker returned no detail";
    };
    const decode = (raw) => {
      let exitCode = null;
      const output = [];
      for (const line of raw.replace(/\r/g, "").split("\n")) {
        if (line.startsWith("__AIUR_CONTROL_EXIT__:")) {
          const value = Number(line.slice("__AIUR_CONTROL_EXIT__:".length));
          if (Number.isInteger(value) && value >= 0 && value <= 255) exitCode = value;
        } else if (line.startsWith("__AIUR_CONTROL_ERROR__:")) {
          output.push(line.slice("__AIUR_CONTROL_ERROR__:".length));
        } else if (line !== "" && line !== ":ok") {
          output.push(line);
        }
      }
      return { exitCode, output: output.join("\n") };
    };

    const rendered = [];
    let highest = 0;
    names.forEach((name, index) => {
      const rawStatus = read(`${dir}/${index}.status`).trim();
      const transport = /^\d+$/.test(rawStatus) ? Number(rawStatus) : null;
      if (transport !== 0) {
        const status = Number.isInteger(transport) ? transport : 69;
        const error = codeFor(status);
        const detail = detailFor(index);
        highest = Math.max(highest, status);
        rendered.push(jsonMode === "1"
          ? JSON.stringify({instance: name, ok: false, error, detail})
          : `== ${name} == ${error}: ${detail}`);
        return;
      }

      const decoded = decode(read(`${dir}/${index}.output`));
      if (decoded.exitCode === null) {
        highest = Math.max(highest, 1);
        const detail = "remote output had no exit marker";
        rendered.push(jsonMode === "1"
          ? JSON.stringify({instance: name, ok: false, error: "invalid_output", detail})
          : `== ${name} == invalid_output: ${detail}`);
        return;
      }

      highest = Math.max(highest, decoded.exitCode);
      if (jsonMode === "1") {
        rendered.push(JSON.stringify({instance: name, ok: true, exit_code: decoded.exitCode, output: decoded.output}));
      } else {
        let host = "unknown";
        try { host = new URL(read(`${dir}/${index}.url`)).host; } catch (_) {}
        rendered.push(`== ${name} (${host}) ==${decoded.output ? `\n${decoded.output}` : ""}`);
      }
    });
    process.stdout.write(`${rendered.join("\n")}${rendered.length ? "\n" : ""}__AIUR_CONTROL_EXIT__:${highest}\n`);
  ' "$result_dir" "${AIUR_REMOTE_ALL_JSON:-0}" "$@"
}

run_remote_all_rpc() {
  local expression="$1" records name _url result_dir output index=0 pid
  local -a names=() pids=()

  records="$(load_remote_instance '*')" || return $?
  result_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-remote-all.XXXXXX")" || {
    control_rpc_say "aiur: could not create fan-out result directory"
    return 69
  }
  chmod 700 "$result_dir"

  while IFS=$'\t' read -r name _url; do
    [ -n "$name" ] || continue
    names+=("$name")
    (run_remote_all_instance "$index" "$name" "$expression" "$result_dir") &
    pids+=("$!")
    index=$((index + 1))
  done <<<"$records"

  for pid in "${pids[@]+"${pids[@]}"}"; do wait "$pid" || true; done
  if output="$(render_remote_all_results "$result_dir" "${names[@]+"${names[@]}"}")"; then
    AIUR_CONTROL_RPC_OUTPUT="$output"
    rm -rf -- "$result_dir"
    return 0
  fi

  rm -rf -- "$result_dir"
  control_rpc_say "aiur: could not render remote fan-out results"
  return 69
}
