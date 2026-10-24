# Named remote-instance registry and HTTP control transport. Sourced by aiur-engine.sh.

AIUR_REMOTE_REGISTRY_DISPLAY="~/.aiur/remote-instances.yaml"

validate_remote_instance_name() {
  local name="${AIUR_REMOTE_INSTANCE:-}"
  [ -n "$name" ] || { echo "aiur: --instance requires a name" >&2; return 64; }
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$name" != "." ] && [ "$name" != ".." ] || {
    echo "aiur: --instance expects a name containing only letters, numbers, '.', '_' or '-'" >&2
    return 64
  }
  [ "$name" != "all" ] || {
    echo "aiur: --instance all is not supported by this client build" >&2
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
    --todo | status | usage | agents | accounts | commands | executor-answer | executor-escalate | executor-reclassify | executor-moot | units | queue | epic | feature | build-orders | analytics | github-cost | experiments | capabilities | ticket-usage | github-usage | alerts | executor-sweep | watch | executor-wait | executor-emit | executor-subscribe | executor-unsubscribe | executor-subscriptions | executor-roster | executor-session | executor-fast-forward | executor-claim | executor-release | executor-revoke | set | pause | resume | park | take | release | reset-budget | workspace-recover | message)
      ;;
    stop | restart)
      echo "aiur: $command is local to the instance's host" >&2
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
      echo "aiur: $command is a local streaming command and is unavailable with --instance" >&2
      return 64
      ;;
    --version | help | -h | -help | --h | --help)
      echo "aiur: $command describes this local client and is unavailable with --instance" >&2
      return 64
      ;;
    *)
      echo "aiur: $command is unavailable with --instance" >&2
      return 64
      ;;
  esac

  case "$command" in
    executor-wait | executor-claim | executor-release | executor-fast-forward)
      remote_command_has_as "$@" || {
        echo "aiur: $command with --instance requires --as <id>" >&2
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

  if [ ! -r "$file" ]; then
    echo "aiur: remote instance registry $AIUR_REMOTE_REGISTRY_DISPLAY is missing or unreadable" >&2
    return 64
  fi

  if record="$(awk -v target="$name" -v display="$AIUR_REMOTE_REGISTRY_DISPLAY" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function invalid(message) {
      print "aiur: invalid remote instance registry " display ":" NR ": " message > "/dev/stderr"
      failed = 1
      exit 65
    }
    function scalar(raw, value, quote, inner) {
      value = trim(raw)
      quote = substr(value, 1, 1)
      if (quote == "\"" || quote == sprintf("%c", 39)) {
        if (length(value) < 2 || substr(value, length(value), 1) != quote) invalid("unterminated quoted scalar")
        inner = substr(value, 2, length(value) - 2)
        if (index(inner, quote) || index(inner, "\\")) invalid("quoted scalars cannot contain escapes")
        value = inner
      } else {
        sub(/[[:space:]]+#.*$/, "", value)
        value = trim(value)
      }
      if (value == "" || value == "~" || value == "null") invalid("expected a non-empty scalar")
      if (value ~ /^[\[\{&*!|>]/) invalid("collections, aliases and tagged scalars are not supported")
      return value
    }
    function finish_instance() {
      if (current == "") return
      if (current_url == "") invalid("instance " current " is missing url")
      if ((current_token_file == "") == (current_token_env == "")) invalid("instance " current " must set exactly one of token_file or token_env")
      if (current == target) {
        print "url\t" current_url
        if (current_token_file != "") print "token_file\t" current_token_file
        else print "token_env\t" current_token_env
        found = 1
      }
      current = current_url = current_token_file = current_token_env = ""
    }
    {
      sub(/\r$/, "")
      if ($0 ~ /\t/) invalid("tabs are not allowed")
      if ($0 ~ /^[[:space:]]*($|#)/) next

      match($0, /^ */)
      indent = RLENGTH
      text = substr($0, indent + 1)

      if (indent == 0) {
        finish_instance()
        if (text ~ /^version:[[:space:]]*/) {
          if (seen_version) invalid("duplicate version")
          version_value = text
          sub(/^version:[[:space:]]*/, "", version_value)
          if (scalar(version_value) != "1") invalid("version must be 1")
          seen_version = 1
        } else if (text ~ /^instances:[[:space:]]*(#.*)?$/) {
          if (seen_instances) invalid("duplicate instances map")
          seen_instances = 1
        } else invalid("expected version or instances")
        next
      }

      if (indent == 2) {
        if (!seen_instances) invalid("instance appears before instances map")
        finish_instance()
        if (text !~ /^[A-Za-z0-9._-]+:[[:space:]]*(#.*)?$/) invalid("invalid instance name")
        current = text
        sub(/:[[:space:]]*(#.*)?$/, "", current)
        if (seen_name[current]) invalid("duplicate instance " current)
        seen_name[current] = 1
        next
      }

      if (indent == 4) {
        if (current == "") invalid("field appears outside an instance")
        if (text !~ /^(url|token_file|token_env):[[:space:]]*/) invalid("unsupported instance field")
        key = text
        sub(/:.*/, "", key)
        value = text
        sub(/^[^:]+:[[:space:]]*/, "", value)
        value = scalar(value)
        if (key == "url") {
          if (current_url != "") invalid("duplicate url")
          current_url = value
        } else if (key == "token_file") {
          if (current_token_file != "") invalid("duplicate token_file")
          current_token_file = value
        } else {
          if (current_token_env != "") invalid("duplicate token_env")
          current_token_env = value
        }
        next
      }

      invalid("expected zero, two or four spaces of indentation")
    }
    END {
      if (failed) exit 65
      finish_instance()
      if (!seen_version) invalid("missing version")
      if (!seen_instances) invalid("missing instances map")
      if (!found) exit 64
    }
  ' "$file")"; then
    :
  else
    status=$?
    if [ "$status" -eq 64 ]; then
      echo "aiur: unknown remote instance '$name' in $AIUR_REMOTE_REGISTRY_DISPLAY" >&2
    fi
    return 64
  fi

  while IFS=$'\t' read -r key value; do
    case "$key" in
      url) AIUR_REMOTE_URL="$value" ;;
      token_file | token_env)
        AIUR_REMOTE_TOKEN_KIND="$key"
        AIUR_REMOTE_TOKEN_REF="$value"
        ;;
    esac
  done <<<"$record"
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
        "~/"*) path="$HOME/${reference#~/}" ;;
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
  local request_file response_file http_status curl_status=0 output code reason detail required_scope build

  validate_remote_instance_name || return $?
  load_remote_instance "$name" || return $?
  validate_remote_url "$name" "$AIUR_REMOTE_URL" || return $?
  load_remote_token "$name" || return $?
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

  timeout_seconds="$(control_rpc_timeout_seconds)"
  timeout_ms=$((timeout_seconds * 1000))
  curl_timeout=$((timeout_seconds + 15))
  request_file="$(mktemp "${TMPDIR:-/tmp}/aiur-remote-request.XXXXXX")"
  response_file="$(mktemp "${TMPDIR:-/tmp}/aiur-remote-response.XXXXXX")"
  chmod 600 "$request_file" "$response_file"

  if ! printf '%s' "$expression" | AIUR_REMOTE_COMMAND="${AIUR_CONTROL_COMMAND:-control}" AIUR_REMOTE_TIMEOUT_MS="$timeout_ms" AIUR_REMOTE_MAX_SCOPE="${AIUR_REMOTE_MAX_SCOPE:-write}" \
    "$runtime" -e '
      const fs = require("node:fs");
      const expression = fs.readFileSync(0, "utf8");
      process.stdout.write(JSON.stringify({
        contract: "aiur.control.call",
        contract_version: 1,
        expression,
        command: process.env.AIUR_REMOTE_COMMAND,
        timeout_ms: Number(process.env.AIUR_REMOTE_TIMEOUT_MS),
        max_scope: process.env.AIUR_REMOTE_MAX_SCOPE,
      }));
    ' >"$request_file"; then
    rm -f "$request_file" "$response_file"
    control_rpc_say "aiur: could not encode the remote control request"
    return 69
  fi

  if http_status="$(printf 'Authorization: Bearer %s\n' "$token" | curl \
    --silent --show-error --request POST \
    --max-time "$curl_timeout" \
    --header @- \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json' \
    --data-binary "@$request_file" \
    --output "$response_file" \
    --write-out '%{http_code}' \
    "$AIUR_REMOTE_URL/api/v1/control")"; then
    :
  else
    curl_status=$?
  fi
  unset token
  rm -f "$request_file"

  AIUR_CONTROL_RPC_TIMED_OUT=0
  RELEASE_NODE="$name"

  if [ "$curl_status" -ne 0 ]; then
    rm -f "$response_file"
    control_rpc_say "aiur: could not reach remote instance '$name' (curl exit $curl_status)"
    return 69
  fi

  case "$http_status" in
    200)
      if output="$(remote_json_output "$response_file")"; then
        AIUR_CONTROL_RPC_OUTPUT="$output"
        rm -f "$response_file"
        return 0
      fi
      rm -f "$response_file"
      control_rpc_say "aiur: remote instance '$name' returned an invalid control response"
      return 69
      ;;
    401)
      rm -f "$response_file"
      control_rpc_say "aiur: token rejected by $name"
      return 77
      ;;
    403)
      required_scope="$(remote_json_field "$response_file" "error.required_scope" 2>/dev/null || true)"
      rm -f "$response_file"
      [ -n "$required_scope" ] || required_scope="required"
      control_rpc_say "aiur: $(control_command_label) requires $required_scope scope on $name"
      return 77
      ;;
    422)
      code="$(remote_json_field "$response_file" "error.code" 2>/dev/null || true)"
      reason="$(remote_json_field "$response_file" "error.reason" 2>/dev/null || true)"
      detail="$(remote_json_field "$response_file" "error.detail" 2>/dev/null || true)"
      build="$(remote_build_label "$response_file")"
      rm -f "$response_file"
      if [ "$reason" = "unknown_on_build" ] || [ "$reason" = "option_not_allowed" ]; then
        control_rpc_say "aiur: $(control_command_label) is unsupported on $name ($build)"
      else
        control_rpc_say "aiur: $(control_command_label) was refused by $name${reason:+: $reason}${detail:+ ($detail)}${code:+ [$code]}"
      fi
      return 64
      ;;
    504)
      rm -f "$response_file"
      control_rpc_say "aiur: $(control_command_label) timed out on $name; outcome unknown on $name"
      return 124
      ;;
    400 | 404 | 405 | 413)
      code="$(remote_json_field "$response_file" "error.code" 2>/dev/null || true)"
      rm -f "$response_file"
      control_rpc_say "aiur: remote instance '$name' refused $(control_command_label) (HTTP $http_status${code:+, $code})"
      return 64
      ;;
    *)
      rm -f "$response_file"
      control_rpc_say "aiur: remote instance '$name' failed $(control_command_label) with HTTP ${http_status:-unknown}"
      return 69
      ;;
  esac
}
