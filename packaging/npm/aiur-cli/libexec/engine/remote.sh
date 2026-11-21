# Named remote-instance registry and HTTP control transport. Sourced by aiur-engine.sh.

AIUR_REMOTE_REGISTRY_DISPLAY="~/.aiur/remote-instances.yaml"

validate_remote_instance_name() {
  local name="${AIUR_REMOTE_INSTANCE:-}"
  [ -n "$name" ] || { echo "aiur: ${AIUR_REMOTE_SELECTOR_FLAG:---instance} requires a name" >&2; return 64; }
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$name" != "." ] && [ "$name" != ".." ] || {
    echo "aiur: ${AIUR_REMOTE_SELECTOR_FLAG:---instance} expects a name containing only letters, numbers, '.', '_' or '-'" >&2
    return 64
  }
}

remote_command_has_as() {
  local arg
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --as)
        [ "$#" -gt 1 ] && [ -n "${2:-}" ] && return 0
        return 1
        ;;
      --as=*) [ -n "${arg#--as=}" ] && return 0 ;;
    esac
    shift
  done
  return 1
}

ensure_remote_command_allowed() {
  local command="${1:-run}"

  case "$command" in
    --todo | status | usage | agents | accounts | command | commands | executor-ack | executor-claim-decision | executor-release-decision | executor-answer | executor-escalate | executor-reclassify | executor-moot | units | queue | lane | epic | feature | build-orders | analytics | github-cost | experiments | capabilities | ticket-usage | github-usage | alerts | executor-sweep | watch | executor-wait | executor-emit | executor-subscribe | executor-unsubscribe | executor-subscriptions | executor-roster | executor-session | executor-fast-forward | executor-claim | executor-release | executor-revoke | config | set | pause | resume | park | take | release | reset-budget | workspace-recover | message | listen-mode | redispatch | rework | ticket | operator-relay-answer)
      ;;
    history)
      [ "${2:-}" = label-writes ] || { echo "aiur: history export is local to the instance's host" >&2; return 64; }
      ;;
    stop | restart | gateway)
      if [ "${AIUR_REMOTE_SELECTOR_FLAG:-}" = --gateway ]; then
        echo "aiur: $command is local to the gateway's host; run it there" >&2
      else
        echo "aiur: $command is local to the instance's host" >&2
      fi
      return 64
      ;;
    run | --bg | "")
      echo "aiur: starting a run is local to the instance's host" >&2
      return 64
      ;;
    cleanup-stale)
      echo "aiur: cleanup-stale inspects processes local to the instance's host" >&2
      return 64
      ;;
    doctor)
      echo "aiur: doctor inspects tools local to this client" >&2
      return 64
      ;;
    upgrade)
      echo "aiur: upgrade changes the CLI installed on this client" >&2
      return 64
      ;;
    pre-pr)
      echo "aiur: pre-pr operates on this client's checkout" >&2
      return 64
      ;;
    init | login | logout | pr | findings | ask | asks)
      echo "aiur: $command operates on state local to this client" >&2
      return 64
      ;;
    answer)
      echo "aiur: answer requires the local operator verification path" >&2
      return 64
      ;;
    listen | executor-listen)
      echo "aiur: $command is a local streaming command and is unavailable with ${AIUR_REMOTE_SELECTOR_FLAG:---instance}" >&2
      return 64
      ;;
    --version | help | -h | -help | --h | --help)
      echo "aiur: $command describes this local client and is unavailable with ${AIUR_REMOTE_SELECTOR_FLAG:---instance}" >&2
      return 64
      ;;
    *)
      echo "aiur: $command is unavailable with ${AIUR_REMOTE_SELECTOR_FLAG:---instance}" >&2
      return 64
      ;;
  esac

  case "$command" in
    executor-wait | executor-claim | executor-release | executor-fast-forward)
      remote_command_has_as "$@" || {
        echo "aiur: $command with ${AIUR_REMOTE_SELECTOR_FLAG:---instance} requires --as <id>" >&2
        return 64
      }
      ;;
  esac
}

remote_registry_path() {
  printf '%s/.aiur/remote-instances.yaml' "${HOME:?HOME is required}"
}

load_remote_instance() {
  local name="$1" file record status key value
  file="$(remote_registry_path)"
  AIUR_REMOTE_URL=""
  AIUR_REMOTE_TOKEN_KIND=""
  AIUR_REMOTE_TOKEN_REF=""
  AIUR_REMOTE_GATEWAY_ID=""
  AIUR_REMOTE_LABEL=""
  AIUR_REMOTE_TLS_PIN=""

  if [ ! -r "$file" ]; then
    echo "aiur: remote instance registry $AIUR_REMOTE_REGISTRY_DISPLAY is missing or unreadable" >&2
    return 64
  fi

  if record="$(awk -f "$engine_dir/engine/registry.awk" -v target="$name" -v display="$AIUR_REMOTE_REGISTRY_DISPLAY" "$file")"; then
    :
  else
    status=$?
    if [ "$status" -eq 64 ]; then
      echo "aiur: unknown remote instance '$name' in $AIUR_REMOTE_REGISTRY_DISPLAY" >&2
    fi
    return 64
  fi

  if [ "$name" = "*" ]; then printf '%s\n' "$record"; return 0; fi

  while IFS=$'\t' read -r key value; do
    case "$key" in
      url) AIUR_REMOTE_URL="$value" ;;
      gateway_id) AIUR_REMOTE_GATEWAY_ID="$value" ;;
      label) AIUR_REMOTE_LABEL="$value" ;;
      tls_pin_sha256) AIUR_REMOTE_TLS_PIN="$value" ;;
      inbound_only)
        echo "aiur: remote instance '$name' is inbound-only (no url)" >&2
        return 64
        ;;
      token_file | token_env)
        AIUR_REMOTE_TOKEN_KIND="$key"
        AIUR_REMOTE_TOKEN_REF="$value"
        ;;
    esac
  done <<<"$record"
}

# curl's --pinnedpubkey wants sha256//<base64>; the registry stores the SPKI hash as hex.
# The pin is the sole endpoint authentication, so --insecure (self-signed certs) is added with it.
remote_tls_pin_args() {
  local runtime pin
  AIUR_REMOTE_CURL_TLS=()
  [ -n "$AIUR_REMOTE_TLS_PIN" ] || return 0
  runtime="$(remote_js_runtime)"
  pin="$("$runtime" -e 'process.stdout.write(Buffer.from(process.argv[1], "hex").toString("base64"))' "$AIUR_REMOTE_TLS_PIN")" || return 69
  AIUR_REMOTE_CURL_TLS=(--insecure --pinnedpubkey "sha256//$pin")
}

remote_js_runtime() {
  if [ -n "${AIUR_JS_RUNTIME:-}" ] && [ -x "$AIUR_JS_RUNTIME" ]; then
    printf '%s' "$AIUR_JS_RUNTIME"
  else
    command -v node 2>/dev/null || true
  fi
}

validate_remote_url() {
  local name="$1" url="$2" runtime normalized
  runtime="$(remote_js_runtime)"
  [ -n "$runtime" ] || {
    echo "aiur: remote control requires Node.js to validate the registry URL" >&2
    return 69
  }

  if normalized="$(printf '%s' "$url" | "$runtime" -e '
    const fs = require("node:fs");
    const raw = fs.readFileSync(0, "utf8");
    let url;
    try { url = new URL(raw); } catch (_) { process.exit(1); }
    if (url.username || url.password || url.search || url.hash || (url.pathname !== "/" && url.pathname !== "")) process.exit(1);
    const host = url.hostname.toLowerCase();
    const octets = host.split(".");
    const ipv4Loopback = octets.length === 4 && octets.every((part) => /^\d+$/.test(part) && Number(part) <= 255) && Number(octets[0]) === 127;
    const loopback = host === "localhost" || host === "::1" || host === "[::1]" || ipv4Loopback;
    if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) process.exit(1);
    process.stdout.write(url.origin);
  ')"; then
    AIUR_REMOTE_URL="$normalized"
    return 0
  fi

  echo "aiur: remote instance '$name' must use HTTPS; plain HTTP is allowed only for 127.0.0.0/8, ::1 or localhost" >&2
  return 64
}

remote_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

load_remote_token() {
  local name="$1" reference="$AIUR_REMOTE_TOKEN_REF" path mode token

  case "$AIUR_REMOTE_TOKEN_KIND" in
    token_env)
      [[ "$reference" =~ ^AIUR_TOKEN_[A-Za-z0-9_]+$ ]] || {
        echo "aiur: remote instance '$name' token_env must name an AIUR_TOKEN_* variable" >&2
        return 64
      }
      token="$(printenv "$reference" 2>/dev/null || true)"
      [ -n "$token" ] || {
        echo "aiur: remote instance '$name' requires environment variable $reference" >&2
        return 64
      }
      ;;
    token_file)
      case "$reference" in
        "~") path="$HOME" ;;
        "~/"*) path="$HOME/${reference#\~/}" ;;
        /*) path="$reference" ;;
        *)
          echo "aiur: remote instance '$name' token_file must be absolute or start with ~/" >&2
          return 64
          ;;
      esac
      [ -f "$path" ] && [ -r "$path" ] || {
        echo "aiur: remote instance '$name' token_file is missing or unreadable" >&2
        return 64
      }
      mode="$(remote_file_mode "$path")"
      [ "${mode#0}" = "600" ] || {
        echo "aiur: remote instance '$name' token_file must have mode 0600" >&2
        return 64
      }
      token="$(cat "$path")"
      ;;
    *)
      echo "aiur: remote instance '$name' has no token reference" >&2
      return 64
      ;;
  esac

  if [ -z "$token" ] || [[ "$token" =~ [[:space:]] ]] || [[ ! "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    echo "aiur: remote instance '$name' token is empty or not bearer-safe" >&2
    return 64
  fi
  AIUR_REMOTE_TOKEN="$token"
}

# Compare the gateway_id in a 200 response with the registry pin; unpinned entries
# get a one-time hint on stderr. Never writes the registry (the human pastes the line).
remote_gateway_check() {
  local name="$1" file="$2" seen state_dir marker old
  seen="$(remote_json_field "$file" "gateway_id" 2>/dev/null || true)"
  if [ -n "$AIUR_REMOTE_GATEWAY_ID" ]; then
    if [ -z "$seen" ]; then
      control_rpc_say "aiur: gateway identity unverified for '$name' (response carries no gateway_id)"
      return 77
    fi
    [ "$seen" = "$AIUR_REMOTE_GATEWAY_ID" ] && return 0
    control_rpc_say "aiur: gateway identity mismatch for '$name'"
    control_rpc_say "aiur: expected $AIUR_REMOTE_GATEWAY_ID, got $seen; the command may have run on the gateway that answered"
    return 77
  fi
  [ -n "$seen" ] || return 0
  state_dir="${AIUR_REMOTE_STATE_DIR:-${HOME:?HOME is required}/.aiur/remote-state}/seen-gateway"
  marker="$state_dir/$name"
  old="$(cat "$marker" 2>/dev/null || true)"
  [ "$old" != "$seen" ] || return 0
  if [ -n "$old" ]; then
    echo "aiur: '$name' now answers as gateway $seen; it answered as $old before. Pin the one you trust." >&2
    return 0
  fi
  echo "aiur: '$name' answered as gateway $seen. To pin it, add under $name: in $AIUR_REMOTE_REGISTRY_DISPLAY:" >&2
  echo "    gateway_id: $seen" >&2
  # A failed marker write is non-fatal: the hint just prints again.
  (umask 077; mkdir -p "$state_dir" && printf '%s' "$seen" >"$marker") 2>/dev/null || true
}

remote_json_field() {
  local file="$1" field="$2" runtime
  runtime="$(remote_js_runtime)"
  "$runtime" -e '
    const fs = require("node:fs");
    let value;
    try {
      value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      for (const key of process.argv[2].split(".")) value = value?.[key];
    } catch (_) { process.exit(2); }
    if (value === undefined || value === null) process.exit(0);
    if (!["string", "number", "boolean"].includes(typeof value)) process.exit(2);
    process.stdout.write(String(value));
  ' "$file" "$field"
}

remote_json_output() {
  local file="$1" runtime
  runtime="$(remote_js_runtime)"
  "$runtime" -e '
    const fs = require("node:fs");
    let body;
    try { body = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (_) { process.exit(2); }
    if (!body || body.contract !== "aiur.control.result" || body.contract_version !== 1 || typeof body.output !== "string") process.exit(2);
    process.stdout.write(body.output);
  ' "$file"
}

remote_rpc_finish() {
  local status="$1" request_file="$2" response_file="$3"
  rm -f -- "$request_file" "$response_file" "$response_file.http-status" "${AIUR_REMOTE_CURL_PID_FILE:-}" "${AIUR_REMOTE_CLEANUP_FILE:-}"
  return "$status"
}

remote_build_label() {
  local file="$1" version commit
  version="$(remote_json_field "$file" "error.build.version" 2>/dev/null || true)"
  [ -n "$version" ] || version="$(remote_json_field "$file" "build.version" 2>/dev/null || true)"
  commit="$(remote_json_field "$file" "error.build.commit" 2>/dev/null || true)"
  [ -n "$commit" ] || commit="$(remote_json_field "$file" "build.commit" 2>/dev/null || true)"
  if [ -n "$version$commit" ]; then
    printf '%s' "$(trim "$version $commit")"
  else
    printf 'unknown build'
  fi
}

run_remote_rpc_with_timeout() {
  local expression="$1" name="$AIUR_REMOTE_INSTANCE" runtime token timeout_seconds timeout_ms curl_timeout
  local request_file response_file http_status curl_status=0 curl_pid output code reason detail required_scope build rpc_status=0 request_id

  if [ "$name" = all ]; then run_remote_all_rpc "$expression"; return $?; fi

  validate_remote_instance_name || return $?
  load_remote_instance "$name" || return $?
  validate_remote_url "$name" "$AIUR_REMOTE_URL" || return $?
  load_remote_token "$name" || return $?
  remote_tls_pin_args || return $?
  token="$AIUR_REMOTE_TOKEN"
  unset AIUR_REMOTE_TOKEN

  runtime="$(remote_js_runtime)"
  [ -n "$runtime" ] || {
    control_rpc_say "aiur: remote control requires Node.js"
    return 69
  }
  command -v curl >/dev/null 2>&1 || {
    control_rpc_say "aiur: remote control requires curl"
    return 69
  }

  request_id="$(aiur_request_id_for_call)" || { control_rpc_say "aiur: could not generate a request id"; return 69; }
  timeout_seconds="$(control_rpc_timeout_seconds)"
  timeout_ms=$((timeout_seconds * 1000))
  curl_timeout=$((timeout_seconds + 15))
  request_file="$(mktemp "${TMPDIR:-/tmp}/aiur-remote-request.XXXXXX")" || { control_rpc_say "aiur: could not create the remote request file"; return 69; }
  response_file="$(mktemp "${TMPDIR:-/tmp}/aiur-remote-response.XXXXXX")" || { rm -f -- "$request_file"; control_rpc_say "aiur: could not create the remote response file"; return 69; }
  chmod 600 "$request_file" "$response_file" || { remote_rpc_finish 69 "$request_file" "$response_file" || true; return 69; }
  [ -z "${AIUR_REMOTE_CLEANUP_FILE:-}" ] || printf '%s\n%s\n%s.http-status\n' "$request_file" "$response_file" "$response_file" >"$AIUR_REMOTE_CLEANUP_FILE"

  if ! printf '%s' "$expression" | AIUR_REMOTE_COMMAND="${AIUR_CONTROL_COMMAND:-control}" AIUR_REMOTE_TIMEOUT_MS="$timeout_ms" AIUR_REMOTE_MAX_SCOPE="${AIUR_REMOTE_MAX_SCOPE:-write}" AIUR_REMOTE_REQUEST_ID="$request_id" \
    "$runtime" -e '
      const fs = require("node:fs");
      const expression = fs.readFileSync(0, "utf8");
      process.stdout.write(JSON.stringify({
        contract: "aiur.control.call",
        contract_version: process.env.AIUR_REMOTE_REQUEST_ID ? 2 : 1,
        request_id: process.env.AIUR_REMOTE_REQUEST_ID || undefined,
        expression,
        command: process.env.AIUR_REMOTE_COMMAND,
        timeout_ms: Number(process.env.AIUR_REMOTE_TIMEOUT_MS),
        max_scope: process.env.AIUR_REMOTE_MAX_SCOPE,
      }));
    ' >"$request_file"; then
    remote_rpc_finish 69 "$request_file" "$response_file" || true
    control_rpc_say "aiur: could not encode the remote control request"
    return 69
  fi

  printf 'Authorization: Bearer %s\n' "$token" | (
    [ -z "${AIUR_REMOTE_CURL_PID_FILE:-}" ] || printf '%s' "$BASHPID" >"$AIUR_REMOTE_CURL_PID_FILE"
    exec curl \
      --silent --show-error --request POST ${AIUR_REMOTE_CURL_TLS[@]+"${AIUR_REMOTE_CURL_TLS[@]}"} \
      --max-time "$curl_timeout" \
      --header @- \
      --header 'Content-Type: application/json' \
      --header 'Accept: application/json' \
      --data-binary "@$request_file" \
      --output "$response_file" \
      --write-out '%{http_code}' \
      "$AIUR_REMOTE_URL/api/v1/control"
  ) >"$response_file.http-status" &
  curl_pid=$!
  if wait "$curl_pid"; then http_status="$(cat "$response_file.http-status" 2>/dev/null || true)"; else curl_status=$?; fi

  AIUR_CONTROL_RPC_TIMED_OUT=0
  RELEASE_NODE="$name"

  if [ "$curl_status" -ne 0 ]; then
    aiur_remote_curl_failure "$name" "$curl_status" "$request_id" || rpc_status=$?
  else
    case "$http_status" in
      200)
        if output="$(remote_json_output "$response_file")"; then
          remote_gateway_check "$name" "$response_file" || { rpc_status=$?; remote_rpc_finish "$rpc_status" "$request_file" "$response_file"; return; }
          AIUR_CONTROL_RPC_OUTPUT="$output"
          AIUR_REMOTE_INSTANCE_ID="$(remote_json_field "$response_file" "instance_id" 2>/dev/null || true)"
        else
          control_rpc_say "aiur: remote instance '$name' returned an invalid control response"
          rpc_status=69
        fi
        ;;
      401)
        control_rpc_say "aiur: token rejected by $name"
        rpc_status=77
        ;;
      403)
        required_scope="$(remote_json_field "$response_file" "error.required_scope" 2>/dev/null || true)"
        [ -n "$required_scope" ] || required_scope="required"
        control_rpc_say "aiur: $(control_command_label) requires $required_scope scope on $name"
        rpc_status=77
        ;;
      422)
        code="$(remote_json_field "$response_file" "error.code" 2>/dev/null || true)"
        reason="$(remote_json_field "$response_file" "error.reason" 2>/dev/null || true)"
        detail="$(remote_json_field "$response_file" "error.detail" 2>/dev/null || true)"
        rpc_status=64
        if [ -n "$request_id" ] && [ "$code" = "parse_error" ]; then
          aiur_remote_v1_retry "$name" "$expression"; rpc_status=$?
        elif [ "$reason" = "unknown_on_build" ] || [ "$reason" = "option_not_allowed" ]; then
          control_rpc_say "aiur: $(control_command_label) is unsupported on $name ($(remote_build_label "$response_file"))"
        else
          control_rpc_say "aiur: $(control_command_label) was refused by $name${reason:+: $reason}${detail:+ ($detail)}${code:+ [$code]}"
        fi
        ;;
      504)
        control_rpc_say "aiur: $(control_command_label) timed out on $name; outcome unknown on $name${request_id:+; $(aiur_request_id_hint "$request_id")}"; rpc_status=124
        ;;
      409) aiur_remote_conflict "$name" "$response_file" "$request_id" || rpc_status=$? ;;
      400 | 404 | 405 | 413)
        code="$(remote_json_field "$response_file" "error.code" 2>/dev/null || true)"
        control_rpc_say "aiur: remote instance '$name' refused $(control_command_label) (HTTP $http_status${code:+, $code})"; rpc_status=64
        ;;
      *)
        control_rpc_say "aiur: remote instance '$name' failed $(control_command_label) with HTTP ${http_status:-unknown}"; rpc_status=69
        ;;
    esac
  fi
  remote_rpc_finish "$rpc_status" "$request_file" "$response_file"
}
