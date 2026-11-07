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
      # An inbound-only peer (no url, no token) exists so the receiver can read allows; it is not callable.
      inbound_only = current_url == "" && current_token_file == "" && current_token_env == "" && (seen_allows || current_gateway_id != "")
      if (inbound_only) {
        if (current == target) { print "inbound_only\t1"; found = 1 }
        current = ""; current_gateway_id = current_label = current_tls_pin = ""; in_allows = seen_allows = 0
        return
      }
      if (current_url == "") invalid("instance " current " is missing url")
      if ((current_token_file == "") == (current_token_env == "")) invalid("instance " current " must set exactly one of token_file or token_env")
      if (target == "*") {
        print current "\t" current_url
        found = 1
      } else if (current == target) {
        print "url\t" current_url
        if (current_gateway_id != "") print "gateway_id\t" current_gateway_id
        if (current_label != "") print "label\t" current_label
        if (current_tls_pin != "") print "tls_pin_sha256\t" current_tls_pin
        if (current_token_file != "") print "token_file\t" current_token_file
        else print "token_env\t" current_token_env
        found = 1
      }
      current = current_url = current_token_file = current_token_env = ""
      current_gateway_id = current_label = current_tls_pin = ""
      in_allows = seen_allows = 0
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
        if (current == "all") invalid("instance name all is reserved")
        if (seen_name[current]) invalid("duplicate instance " current)
        seen_name[current] = 1
        next
      }

      # allows: is owned by the inbound receiver; skip its nested block unvalidated.
      if (indent >= 6 && in_allows) next
      if (indent == 4) {
        if (current == "") invalid("field appears outside an instance")
        in_allows = 0
        if (text ~ /^allows:[[:space:]]*(#.*)?$/) {
          if (seen_allows) invalid("duplicate allows")
          seen_allows = in_allows = 1
          next
        }
        if (text !~ /^(url|token_file|token_env|gateway_id|label|tls_pin_sha256):[[:space:]]*/) invalid("unsupported instance field")
        key = text
        sub(/:.*/, "", key)
        value = text
        sub(/^[^:]+:[[:space:]]*/, "", value)
        value = scalar(value)
        if (key == "url") {
          if (current_url != "") invalid("duplicate url")
          current_url = value
        } else if (key == "gateway_id") {
          if (current_gateway_id != "") invalid("duplicate gateway_id")
          if (length(value) != 26 || value !~ /^[a-z2-7]+$/) invalid("gateway_id must be 26 base32 characters")
          current_gateway_id = value
        } else if (key == "label") {
          if (current_label != "") invalid("duplicate label")
          if (length(value) > 64) invalid("label must be 1-64 characters")
          current_label = value
        } else if (key == "tls_pin_sha256") {
          if (current_tls_pin != "") invalid("duplicate tls_pin_sha256")
          if (length(value) != 64 || value !~ /^[0-9a-f]+$/) invalid("tls_pin_sha256 must be 64 lowercase hex characters")
          current_tls_pin = value
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
      if (!found && target != "*") exit 64
    }
