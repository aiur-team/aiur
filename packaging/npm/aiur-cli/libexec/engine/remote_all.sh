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

  if [ "$command" = executor-wait ]; then
    remote_command_has_as "$@" || {
      echo "aiur: executor-wait with --instance requires --as <id>" >&2
      return 64
    }
    AIUR_REMOTE_ALL_WAIT=1
    local wait_arg
    local previous_wait_arg=""
    for wait_arg in "$@"; do
      case "$wait_arg" in
        --timeout | --as) [ -z "$previous_wait_arg" ] || { echo "aiur: executor-wait with --instance accepts --timeout, --as and --json" >&2; return 64; }; previous_wait_arg="$wait_arg" ;;
        --timeout=* | --as=* | --json) previous_wait_arg="" ;;
        *) if [ -n "$previous_wait_arg" ]; then previous_wait_arg=""; else echo "aiur: executor-wait with --instance accepts --timeout, --as and --json" >&2; return 64; fi ;;
      esac
    done
    [ -z "$previous_wait_arg" ] || { echo "aiur: executor-wait with --instance accepts --timeout, --as and --json" >&2; return 64; }
    return 0
  fi

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
  AIUR_REMOTE_MAX_SCOPE="${AIUR_REMOTE_ALL_MAX_SCOPE:-read}"
  AIUR_CONTROL_RPC_OUTPUT=""

  run_remote_rpc_with_timeout "$expression" 2>"$result_dir/$index.error" || status=$?
  printf '%s' "$status" >"$result_dir/$index.status"
  printf '%s' "${AIUR_CONTROL_RPC_OUTPUT:-}" >"$result_dir/$index.output"
  printf '%s' "${AIUR_REMOTE_INSTANCE_ID:-}" >"$result_dir/$index.instance_id"
  printf '%s' "${AIUR_REMOTE_URL:-}" >"$result_dir/$index.url"
}

run_remote_all_executor_wait() {
  local timeout=300 as="" json=0 arg records name _url result_dir index=0 pid output exit_code cursor_file cursor_id cursor_value state_dir pending_count next_index
  local wait_output_file
  local state_root="$HOME/.aiur"
  local -a names=() pids=()
  local selected_instance="${AIUR_REMOTE_INSTANCE:-all}"
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --timeout) shift; timeout="${1:-}" ;;
      --timeout=*) timeout="${arg#--timeout=}" ;;
      --as) shift; as="${1:-}" ;;
      --as=*) as="${arg#--as=}" ;;
      --json) json=1 ;;
      *) echo "aiur: executor-wait with --instance accepts --timeout, --as and --json" >&2; return 64 ;;
    esac
    shift
  done
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { echo "aiur: executor-wait --timeout expects a positive integer" >&2; return 64; }
  [ "$timeout" -le 600 ] || { echo "aiur: remote executor-wait --timeout cannot exceed 600 seconds" >&2; return 64; }
  [ -n "$as" ] && [[ "$as" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "aiur: executor-wait with --instance requires --as <id>" >&2; return 64; }
  AIUR_REMOTE_ALL_JSON="$json"
  AIUR_REMOTE_ALL_MAX_SCOPE=write
  export AIUR_REMOTE_ALL_MAX_SCOPE
  state_dir="$state_root/remote-state"
  mkdir -p "$state_dir"
  if [ "$selected_instance" = all ]; then
    records="$(load_remote_instance '*')" || return $?
  else
    load_remote_instance "$selected_instance" || return $?
    records="$(printf '%s\t%s' "$selected_instance" "$AIUR_REMOTE_URL")"
  fi
  result_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-remote-wait.XXXXXX")" || return 69
  chmod 700 "$result_dir"
  index=0
  while IFS=$'\t' read -r name _url; do
    [ -n "$name" ] || continue
    names+=("$name")
    cursor_file="$state_dir/$name.wake-ack"
    [ -e "$cursor_file" ] || printf -- '-\t0\n' >"$cursor_file"
    chmod 600 "$cursor_file"
    IFS=$'\t' read -r cursor_id cursor_value <"$cursor_file" || true
    [[ "$cursor_value" =~ ^(0|[1-9][0-9]*)$ ]] || cursor_value=0
    (run_remote_all_wait_instance "$index" "$name" "$timeout" "$as" "$result_dir" "$state_dir") &
    pids+=("$!")
    index=$((index + 1))
  done <<<"$records"
  while :; do
    if remote_wait_has_delivered_records "$result_dir" "${#names[@]}"; then
      for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
      for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
      for index in "${!names[@]}"; do
        if [ ! -f "$result_dir/$index.status" ]; then
          # A cancelled request was never acknowledged, so its wakes remain available.
          printf '0' >"$result_dir/$index.status"
          printf '{"status":"timeout","role":"owner","records":[]}\n' >"$result_dir/$index.output"
        fi
      done
      break
    fi
    pending_count=0
    for index in "${!names[@]}"; do [ -f "$result_dir/$index.status" ] || pending_count=$((pending_count + 1)); done
    [ "$pending_count" -gt 0 ] || break
    sleep 0.1
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  wait_output_file="$result_dir/rendered"
  if render_remote_all_wait_results "$result_dir" "${names[@]+"${names[@]}"}" >"$wait_output_file"; then
    output="$(cat "$wait_output_file")"
    exit_code="${output##*__AIUR_CONTROL_EXIT__:}"
    [[ "$exit_code" =~ ^[0-9]+$ ]] || exit_code=69
    output="${output%$'\n'__AIUR_CONTROL_EXIT__:*}"
    output="${output%$'\n'}"
    # Control RPCs reserve stdout, so surface the batch on stderr before advancing cursors.
    control_rpc_echo_output "$output"
    index=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      cursor_file="$state_dir/$name.wake-ack"
      if [ -f "$result_dir/$index.cursor" ]; then
        cursor_value="$(cat "$result_dir/$index.cursor")"
        cursor_id="$(cat "$result_dir/$index.instance_id" 2>/dev/null || true)"
        [ -n "$cursor_id" ] || IFS=$'\t' read -r cursor_id _ <"$cursor_file"
        [ -n "$cursor_id" ] || cursor_id="-"
        printf '%s\t%s\n' "$cursor_id" "$cursor_value" >"$cursor_file.tmp"
        chmod 600 "$cursor_file.tmp"
        mv -f -- "$cursor_file.tmp" "$cursor_file"
      fi
      index=$((index + 1))
    done < <(printf '%s\n' "${names[@]}")
    AIUR_CONTROL_RPC_OUTPUT="$output"
    rm -rf -- "$result_dir"
    return "$exit_code"
  fi
  rm -rf -- "$result_dir"
  return 69
}

remote_wait_has_delivered_records() {
  local result_dir="$1" count="$2" runtime
  runtime="$(remote_js_runtime)"
  "$runtime" -e '
    const fs = require("node:fs");
    const [dir, count] = process.argv.slice(1);
    for (let index = 0; index < Number(count); index++) {
      if (fs.existsSync(`${dir}/${index}.status`) && fs.readFileSync(`${dir}/${index}.status`, "utf8") === "0") {
        const raw = fs.readFileSync(`${dir}/${index}.output`, "utf8");
        for (const line of raw.split(/\r?\n/)) {
          try { const payload = JSON.parse(line); if (payload.status === "woken" && payload.records?.length) process.exit(0); } catch (_) {}
        }
      }
    }
    process.exit(1);
  ' "$result_dir" "$count"
}

run_remote_all_wait_instance() {
  local index="$1" name="$2" timeout="$3" as="$4" result_dir="$5" state_dir="$6" cursor_file="$state_dir/$name.wake-ack" cursor=0 instance_id="" expression status=0
  AIUR_REMOTE_INSTANCE="$name"
  AIUR_REMOTE_MAX_SCOPE=write
  AIUR_CONTROL_COMMAND=executor-wait
  AIUR_CONTROL_RPC_TIMEOUT_SECONDS=$((timeout + 10))
  AIUR_REMOTE_INSTANCE_ID=""
  mkdir -p "$(dirname "$cursor_file")"
  if [ -r "$cursor_file" ]; then
    IFS=$'\t' read -r instance_id cursor <"$cursor_file" || true
  fi
  [ "$instance_id" != "-" ] || instance_id=""
  [[ "$cursor" =~ ^(0|[1-9][0-9]*)$ ]] || cursor=0
  printf '%s' "$cursor" >"$result_dir/$index.sent_cursor"
  expression="Aiur.AgentControlCLI.executor_wait(timeout_ms: $((timeout * 1000)), json: true, defer_ack: true, ack_through: $cursor, as: \"$as\")"
  run_remote_rpc_with_timeout "$expression" 2>"$result_dir/$index.error" || status=$?
  printf '%s' "$status" >"$result_dir/$index.status"
  printf '%s' "${AIUR_CONTROL_RPC_OUTPUT:-}" >"$result_dir/$index.output"
  printf '%s' "${AIUR_REMOTE_INSTANCE_ID:-}" >"$result_dir/$index.instance_id"
  printf '%s' "$instance_id" >"$result_dir/$index.previous_instance"
  if [ "$status" -eq 64 ] && grep -q 'is unsupported on' "$result_dir/$index.error"; then printf 'unsupported' >"$result_dir/$index.status"; fi
}

render_remote_all_wait_results() {
  local result_dir="$1" runtime
  shift
  runtime="$(remote_js_runtime)"
  "$runtime" -e '
    const fs = require("node:fs");
    const [dir, jsonMode, ...names] = process.argv.slice(1);
    const read = (file) => { try { return fs.readFileSync(file, "utf8"); } catch (_) { return ""; } };
    const rows = []; let received = false; let highest = 0;
    names.forEach((instance, index) => {
      const status = read(`${dir}/${index}.status`);
      const raw = read(`${dir}/${index}.output`);
      if (status === "unsupported") { rows.push({instance, status: "unsupported", records: [], detail: read(`${dir}/${index}.error`).trim()}); return; }
      if (status !== "0") {
        const detail = read(`${dir}/${index}.error`).trim();
        if (status === "1" && detail.includes("acknowledge")) {
          rows.push({instance, status: "reset", records: [], instance_id: read(`${dir}/${index}.instance_id`), previous_instance: read(`${dir}/${index}.previous_instance`), detail});
          return;
        }
        highest = Math.max(highest, Number(status) || 69);
        rows.push({instance, status: "error", records: [], detail});
        return;
      }
    const lines = raw.replace(/\r/g, "").split("\n").filter((line) => line && line !== ":ok" && !line.startsWith("__AIUR_CONTROL_EXIT__:"));
      let payload = null;
      for (const line of lines) { try { payload = JSON.parse(line); } catch (_) {} }
      if (!payload || !["woken", "timeout", "error"].includes(payload.status)) { highest = Math.max(highest, 69); rows.push({instance, status: "error", records: [], detail: "invalid executor-wait JSON"}); return; }
      payload.instance_id = read(`${dir}/${index}.instance_id`);
      const previous = read(`${dir}/${index}.previous_instance`);
      const reset = payload.status === "error" && payload.stage === "acknowledge" || (previous && payload.instance_id && previous !== payload.instance_id);
      if (reset) { payload.records = []; payload.status = "timeout"; payload._cursor_reset = true; }
      if (payload.instance_id && payload.status !== "error") {
        fs.writeFileSync(`${dir}/${index}.cursor`, reset ? "0" : read(`${dir}/${index}.sent_cursor`));
        fs.writeFileSync(`${dir}/${index}.instance_id`, payload.instance_id);
      }
      if (payload.status === "woken" && Array.isArray(payload.records) && payload.records.length) received = true;
      rows.push({instance, ...payload});
    });
    const printable = rows.filter((row) => row.status === "unsupported" || row.status === "error" || row.status === "reset" || row._cursor_reset || received && row.status === "woken" || !received && row.status === "timeout");
    for (const row of rows) if (row._cursor_reset || row.status === "reset") {
      fs.writeFileSync(`${dir}/${names.indexOf(row.instance)}.cursor`, "0");
      process.stderr.write(`aiur: wake cursor reset for ${row.instance}; resuming from 0\n`);
    }
    if (received) for (const row of rows) if (row.status === "woken" && row.records?.length) {
      const index = names.indexOf(row.instance);
      const ack = Math.max(0, ...row.records.map((record) => Number(record.wake_id) || 0));
      fs.writeFileSync(`${dir}/${index}.cursor`, String(ack));
      fs.writeFileSync(`${dir}/${index}.instance_id`, row.instance_id || "");
      fs.writeFileSync(`${dir}/${index}.delivered`, "1");
    }
    for (const row of printable) process.stdout.write(jsonMode === "1" ? JSON.stringify(row.status === "reset" ? {...row, status: "timeout", detail: "journal reset; cursor reset to 0"} : row) + "\n" : row.status === "woken" ? row.records.map((record) => `[${row.instance}] ${JSON.stringify(record)}`).join("\n") + "\n" : `[${row.instance}] ${row.status === "reset" ? "timeout" : row.status}${row.detail ? `: ${row.detail}` : ""}\n`);
    process.stdout.write(`__AIUR_CONTROL_EXIT__:${highest}\n`);
  ' "$result_dir" "${AIUR_REMOTE_ALL_JSON:-0}" "$@"
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
