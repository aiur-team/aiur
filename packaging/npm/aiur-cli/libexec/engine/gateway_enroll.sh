# `aiur gateway join` and `aiur gateway register`: write this machine's registry entry for a peer. Sourced by aiur-gateway.sh.
# Both run in the shell because the joining side needs no running daemon. Nothing is written until every check has passed.

gateway_entry_exists() {
  [ -f "$1" ] && awk -v n="  $2:" '$0 == n { found = 1 } END { exit !found }' "$1"
}

# Appends one entry to remote-instances.yaml (name url token_file gateway_id label pin). The result must still pass
# registry.awk or the old file stays in place. The entry goes at the end, so `instances:` must be the last top-level key.
gateway_registry_add() {
  local name="$1" url="$2" token_file="$3" gateway_id="$4" label="$5" pin="$6" file dir tmp value
  for value in "$url" "$token_file" "$label"; do
    case "$value" in *'"'* | *"'"* | *\\* | *$'\n'* | *$'\t'*) gateway_usage_error 'registry values cannot contain quotes, backslashes or tabs' ;; esac
  done
  file="$(remote_registry_path)"
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.remote-instances.XXXXXX")"
  if [ -s "$file" ]; then
    awk '/^instances:[[:space:]]*(#.*)?$/ { seen = 1; next } seen && /^[^[:space:]#]/ { bad = 1 } END { exit !(seen && !bad) }' "$file" ||
      { rm -f "$tmp"; echo "aiur: $file does not end with an instances: block; add $name by hand" >&2; return 65; }
    cat "$file" >"$tmp"
    [ -z "$(tail -c1 "$tmp")" ] || printf '\n' >>"$tmp"
  else
    printf 'version: 1\ninstances:\n' >"$tmp"
  fi
  {
    printf '  %s:\n    url: "%s"\n    token_file: "%s"\n' "$name" "$url" "$token_file"
    [ -z "$gateway_id" ] || printf '    gateway_id: "%s"\n' "$gateway_id"
    [ -z "$label" ] || printf '    label: "%s"\n' "$label"
    [ -z "$pin" ] || printf '    tls_pin_sha256: "%s"\n' "$pin"
  } >>"$tmp"
  LC_ALL=C awk -f "$engine_dir/engine/registry.awk" -v target="$name" -v display="$file" "$tmp" >/dev/null || { rm -f "$tmp"; return 65; }
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}

gateway_check_peer_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] && [ "$1" != all ] && [ "$1" != local ] ||
    gateway_usage_error "invalid peer name '$1'; use letters, digits, '.', '_' or '-'"
  ! gateway_entry_exists "$(remote_registry_path)" "$1" || gateway_usage_error "$1 is already in $(remote_registry_path); run 'aiur gateway remove $1' first"
}

# register <name> --url <u> --token-file <f> [--tls-pin <hex>]: no invite, no Tailscale.
gateway_register() {
  local name="$1" url="$2" token_file="$3" pin="$4"
  gateway_check_peer_name "$name"
  [ -n "$url" ] && [ -n "$token_file" ] || gateway_usage_error 'gateway register requires --url and --token-file'
  [ -z "$pin" ] || [[ "$pin" =~ ^[0-9a-f]{64}$ ]] || gateway_usage_error '--tls-pin must be 64 lowercase hex characters'
  [ -f "$token_file" ] || gateway_usage_error "token file $token_file does not exist"
  case "$token_file" in /*) ;; *) token_file="$(cd "$(dirname "$token_file")" && pwd)/$(basename "$token_file")" ;; esac
  validate_remote_url "$name" "$url" || return $?
  gateway_registry_add "$name" "$AIUR_REMOTE_URL" "$token_file" "" "" "$pin" || return $?
  echo "Registered $name at $AIUR_REMOTE_URL."
}

gateway_curl() { # curl_args... ; JSON on stdout, HTTP status on the last line
  curl -sS --max-time 15 -w '\n%{http_code}' ${AIUR_REMOTE_CURL_TLS[@]+"${AIUR_REMOTE_CURL_TLS[@]}"} "$@"
}

# join <code> --name <n>
gateway_join() {
  local code="$1" name="$2" runtime fields key value url gateway_id pin id secret exp now identity own_id own_label hello answer status body
  gateway_check_peer_name "$name"
  [ -n "$code" ] || gateway_usage_error 'gateway join requires an invite code'
  runtime="$(remote_js_runtime)"
  [ -n "$runtime" ] || { echo 'aiur: gateway join requires Node.js' >&2; return 69; }

  fields="$(printf '%s' "$code" | "$runtime" -e '
    const raw = require("node:fs").readFileSync(0, "utf8").trim();
    let c;
    try {
      if (!raw.startsWith("aiur-invite:")) throw 0;
      c = JSON.parse(Buffer.from(raw.slice(12), "base64url").toString("utf8"));
    } catch (_) { process.exit(2); }
    if (c.v !== 1) process.exit(3);
    const ok = (k) => typeof c[k] === "string" && c[k] !== "" && !/[\t\n]/.test(c[k]);
    if (!["url", "gateway_id", "id", "secret"].every(ok) || !Number.isInteger(c.exp) || (c.fp !== null && !/^[0-9a-f]{64}$/.test(c.fp))) process.exit(2);
    for (const k of ["url", "gateway_id", "fp", "id", "secret", "exp"]) console.log(k + "\t" + (c[k] ?? ""));
  ')" || {
    case $? in 3) gateway_usage_error 'unsupported invite version' ;; *) gateway_usage_error 'not a valid invite code' ;; esac
  }
  while IFS=$'\t' read -r key value; do
    case "$key" in url) url="$value" ;; gateway_id) gateway_id="$value" ;; fp) pin="$value" ;; id) id="$value" ;; secret) secret="$value" ;; exp) exp="$value" ;; esac
  done <<<"$fields"
  now="$(date +%s)"
  [ "$now" -lt "$exp" ] || { echo 'aiur: the invite has expired; ask for a new one' >&2; return 65; }

  identity="${AIUR_BG_STATE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aiur}/machine/identity.json"
  [ -r "$identity" ] || { echo "aiur: this machine has no gateway identity yet; start aiur once, then join" >&2; return 66; }
  fields="$("$runtime" -e 'const i = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")); console.log(i.machine_id + "\t" + i.machine_label)' "$identity")" || return 66
  own_id="${fields%%$'\t'*}"
  own_label="${fields#*$'\t'}"

  validate_remote_url "$name" "$url" || return $?
  url="$AIUR_REMOTE_URL"
  AIUR_REMOTE_TLS_PIN="$pin"
  remote_tls_pin_args || return $?
  if [ -z "$pin" ]; then
    echo "warning: no TLS pin; trusting whatever certificate answers at $url" >&2
  fi

  # Verify B before disclosing the secret.
  hello="$(gateway_curl "$url/api/v1/gateway/hello")" || {
    echo "aiur: could not reach $url${pin:+ with the pinned certificate}; nothing was sent or written" >&2
    return 69
  }
  status="${hello##*$'\n'}"
  body="${hello%$'\n'*}"
  [ "$status" = 200 ] || { echo "aiur: $url answered HTTP $status to hello; is gateway_hello enabled there?" >&2; return 65; }
  answer="$(printf '%s' "$body" | "$runtime" -e 'const h = JSON.parse(require("node:fs").readFileSync(0, "utf8")); console.log(h.gateway_id + "\t" + h.enrollment)')" || return 65
  [ "${answer%%$'\t'*}" = "$gateway_id" ] || { echo "aiur: the gateway at $url is not the one that issued this invite; nothing was sent" >&2; return 65; }
  [ "${answer#*$'\t'}" = open ] || { echo "aiur: $url is not accepting enrolment; ask for a new invite" >&2; return 65; }

  local request response
  request="$(AIUR_E_ID="$id" AIUR_E_SECRET="$secret" AIUR_E_GW="$own_id" AIUR_E_LABEL="$own_label" "$runtime" -e '
    const e = process.env;
    process.stdout.write(JSON.stringify({ id: e.AIUR_E_ID, secret: e.AIUR_E_SECRET, gateway_id: e.AIUR_E_GW, label: e.AIUR_E_LABEL }));
  ')"
  response="$(printf '%s' "$request" | gateway_curl -X POST -H 'content-type: application/json' --data-binary @- "$url/api/v1/gateway/enroll")" || {
    echo "aiur: no answer to the enrol request. If $url enrolled this machine, run 'aiur gateway remove' for it there and ask for a new invite" >&2
    return 69
  }
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [ "$status" != 200 ]; then
    echo "aiur: enrolment refused (HTTP $status: $(printf '%s' "$body" | "$runtime" -e 'try { console.log(JSON.parse(require("node:fs").readFileSync(0, "utf8")).error) } catch (_) { console.log("unreadable body") }')); nothing was written" >&2
    return 65
  fi
  fields="$(printf '%s' "$body" | "$runtime" -e '
    const r = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
    if (!/^aiur_[A-Za-z0-9_-]+$/.test(r.token) || typeof r.gateway_id !== "string") process.exit(1);
    console.log("gateway_id\t" + r.gateway_id); console.log("token\t" + r.token); console.log("label\t" + (r.label ?? ""));
    console.log("granted\t" + (r.granted || []).join(",")); console.log("pending\t" + (r.pending || []).join(","));
  ')" || { echo 'aiur: the enrol response was malformed; nothing was written' >&2; return 65; }
  local token="" label="" granted="" pending=""
  while IFS=$'\t' read -r key value; do
    case "$key" in gateway_id) answer="$value" ;; token) token="$value" ;; label) label="$value" ;; granted) granted="$value" ;; pending) pending="$value" ;; esac
  done <<<"$fields"
  [ "$answer" = "$gateway_id" ] || { echo 'aiur: the enrol response named a different gateway; nothing was written' >&2; return 65; }

  local peers_dir="$HOME/.aiur/peers" token_file
  token_file="$peers_dir/$name.token"
  mkdir -p "$peers_dir"
  chmod 700 "$peers_dir" 2>/dev/null || true
  (umask 077 && printf '%s' "$token" >"$token_file")
  chmod 600 "$token_file"
  gateway_registry_add "$name" "$url" "$token_file" "$gateway_id" "$label" "$pin" || { rm -f "$token_file"; return 65; }
  echo "Joined $name at $url (gateway ${gateway_id:0:8}); it granted this machine: ${granted:-read}."
  [ -z "$pending" ] || echo "pending on $name: ${pending//,/, } (confirm in its dashboard, signed in)"
}
