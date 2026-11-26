# Dashboard and CLI evidence helpers for executor-retrospective.sh.

# Read @aiur_control_url from one tmux server. Aiur publishes it only once the
# HTTP listener is actually bound (src/lib/aiur/pane_manager/anchor.ex), and
# scripts/aiur.tmux.conf seeds the option empty, so both "absent" and "present
# but empty" mean the same thing: this server has no dashboard to offer.
dashboard_url_from_socket() {
  local tmux_bin="$1" socket="$2" url
  if [ -n "$socket" ]; then
    url="$("$tmux_bin" -L "$socket" show-options -gqv @aiur_control_url 2>/dev/null || true)"
  else
    url="$("$tmux_bin" show-options -gqv @aiur_control_url 2>/dev/null || true)"
  fi
  case "$url" in
    http://*|https://*) printf '%s\n' "${url%/}" ;;
    *) return 1 ;;
  esac
}

# Discover the daemon dashboard. Every rung reads a URL that Aiur itself
# published; there is deliberately no port guess. A guessed port cannot tell
# the Aiur dashboard apart from any other listener, and writing a stranger's
# pages into the hourly narrative as if they were the daemon's is worse than
# the explicit attention verdict a failed discovery produces.
#
# On success stdout is "url<TAB>socket": the dashboard URL and the tmux socket
# (empty for the URL override or the ambient server) whose server published
# it. visual_check() reuses the socket for the credential fallback so it reads
# the same daemon whose dashboard it is about to capture, never a sibling
# instance on the host.
dashboard_url() {
  local url tmux_bin socket socket_dir candidate found found_socket

  if [ -n "${AIUR_DASHBOARD_URL:-}" ]; then
    printf '%s\t%s\n' "${AIUR_DASHBOARD_URL%/}" ""
    return 0
  fi

  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || return 1

  # 1. The socket the caller named. This is also the disambiguator when more
  # than one Aiur daemon is live on the host.
  if [ -n "${AIUR_TMUX_SOCKET:-}" ]; then
    url="$(dashboard_url_from_socket "$tmux_bin" "$AIUR_TMUX_SOCKET" || true)"
    [ -n "$url" ] && { printf '%s\t%s\n' "$url" "$AIUR_TMUX_SOCKET"; return 0; }
  fi

  # 2. The ambient tmux server, for an Executor running inside the session.
  url="$(dashboard_url_from_socket "$tmux_bin" '' || true)"
  [ -n "$url" ] && { printf '%s\t%s\n' "$url" ""; return 0; }

  # 3. Live aiur-* tmux servers on this host. The Executor usually runs
  # outside the daemon's tmux session, so the ambient server above is its own,
  # not Aiur's; without this sweep discovery can never see the daemon at all.
  socket_dir="${AIUR_TMUX_SOCKET_DIR:-${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)}"
  [ -d "$socket_dir" ] || return 1

  # Prefer a socket that names this run before considering any other.
  if [ -n "${AIUR_EXECUTOR_RUN_ID:-}" ]; then
    for socket in "$socket_dir"/aiur-*"$AIUR_EXECUTOR_RUN_ID"*; do
      [ -S "$socket" ] || continue
      url="$(dashboard_url_from_socket "$tmux_bin" "$(basename "$socket")" || true)"
      [ -n "$url" ] && { printf '%s\t%s\n' "$url" "$(basename "$socket")"; return 0; }
    done
  fi

  # Otherwise accept a sweep result only when it is unambiguous. Several live
  # daemons publishing different URLs means we cannot tell which one this
  # Executor owns, and picking by glob order would silently audit the wrong
  # fleet. Refusing sends the operator to AIUR_TMUX_SOCKET instead.
  found=""
  found_socket=""
  for socket in "$socket_dir"/aiur-*; do
    [ -S "$socket" ] || continue
    candidate="$(dashboard_url_from_socket "$tmux_bin" "$(basename "$socket")" || true)"
    [ -n "$candidate" ] || continue
    if [ -z "$found" ]; then
      found="$candidate"
      found_socket="$(basename "$socket")"
    elif [ "$found" != "$candidate" ]; then
      return 1
    fi
  done

  [ -n "$found" ] || return 1
  printf '%s\t%s\n' "$found" "$found_socket"
}

# Find the daemon BEAM process under one tmux pane. The pane runs the release
# launcher chain (shell → launcher script → bin/aiur → beam.smp), so the BEAM
# is a descendant of the pane PID. Scoped to the pane's subtree so a host
# running several daemons can never read the wrong instance's credentials.
beam_descendant() {
  local frontier="$1" pid ppid next_ppid i
  for i in 1 2 3 4 5 6 7 8; do
    next_ppid=""
    for pid in /proc/[0-9]*; do
      pid="${pid#/proc/}"
      ppid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || true)"
      case " $frontier " in
        *" $ppid "*) ;;
        *) continue ;;
      esac
      if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- 'beam.smp'; then
        printf '%s\n' "$pid"
        return 0
      fi
      next_ppid="${next_ppid:+$next_ppid }$pid"
    done
    [ -n "$next_ppid" ] || return 1
    frontier="$next_ppid"
  done
  return 1
}

# Read one variable from the running daemon's environment. The BEAM loads .env
# itself, so the authoritative copy lives in /proc/<beam>/environ; the tmux
# server's environment is only what a pane inherited and can be stale. The
# read is scoped to the same socket that published the dashboard URL so a
# multi-daemon host never mixes one instance's credentials into another's
# capture. A concrete (non-empty) socket is required: an operator-set
# AIUR_DASHBOARD_URL has no daemon socket attached, and probing the ambient
# server for credentials would risk reading a stranger's pane.
daemon_env_var() {
  local var="$1" socket="$2" tmux_bin pane_pid beam_pid value pane_pids
  [ -n "$socket" ] || return 1
  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || return 1

  pane_pids="$("$tmux_bin" -L "$socket" list-panes -a -F '#{pane_pid}' 2>/dev/null || true)"
  [ -n "$pane_pids" ] || return 1

  # Try every pane, not just the first: the daemon pane is the session's first
  # window in the common case, but a TUI or agent pane may sort ahead, and
  # stopping at the first pane would miss credentials the daemon BEAM does hold.
  for pane_pid in $pane_pids; do
    [[ "$pane_pid" =~ ^[1-9][0-9]*$ ]] || continue

    beam_pid="$(beam_descendant "$pane_pid" || true)"
    if [ -n "$beam_pid" ]; then
      # -r guards the read so a pane that exited between list-panes and here
      # cannot leak a "No such file or directory" onto the check's stderr.
      value="$( { [ -r "/proc/$beam_pid/environ" ] && tr '\0' '\n' < "/proc/$beam_pid/environ"; } 2>/dev/null | sed -n "s/^${var}=//p" | head -n 1 || true)"
      [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    fi

    # The pane shell's own environment is a weaker source (it misses variables
    # the BEAM loaded from .env itself) but is better than failing when the
    # BEAM is not a recognizable descendant of the pane.
    value="$( { [ -r "/proc/$pane_pid/environ" ] && tr '\0' '\n' < "/proc/$pane_pid/environ"; } 2>/dev/null | sed -n "s/^${var}=//p" | head -n 1 || true)"
    [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
  done
  return 1
}

# Write the "did not run" evidence for a precondition failure. Both the
# narrative verdict and the machine-readable report say "did not run" — never
# "attention" — so a wrapper that reads either artifact (or an empty stdout
# log) can never mistake a skipped check for one that ran and found nothing.
# Direct invocations of capture-dashboard.mjs write the same two files, so a
# wrapper sees one consistent shape whether the failure was caught here or in
# the browser script.
write_did_not_run() {
  local dir="$1" detail="$2" message="$3" base="${4:-}"
  cat > "$dir/verdict.md" <<EOF
# Dashboard visual check

- capture: **did not run** — $message

Overall: **did not run**. Captures were not attempted.
EOF
  cat > "$dir/report.json" <<EOF
{
  "checkedAt": "$(now_iso)",
  "baseUrl": "$base",
  "verdict": "did-not-run",
  "precondition": "$detail",
  "pages": []
}
EOF
}

# Capture the four operator-facing reports and append their compact verdict to
# the same durable narrative as the hourly retrospective. The browser work is
# intentionally outside the retrospective lock: a Playwright startup must not
# block a concurrent observation or a timer-state update. Only the append is
# serialized.
visual_check() {
  local capture_script capture_dir dashboard_base_url timestamp capture_status verdict
  local dashboard_socket dashboard_username dashboard_password discovery
  local url_source username_source password_source socket_label
  local url_argument=0
  local url_override="${AIUR_DASHBOARD_URL:-}"
  # "$@" still carries the subcommand word (the dispatcher never shifts), so
  # $1 is "visual-check" and an operator-supplied base URL arrives as $2.
  # Accepting that argument is what makes the documented URL override usable
  # from the command line as well as from the environment.
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || {
    printf 'usage: %s visual-check [dashboard-url]\n' "$0" >&2
    return 64
  }
  if [ "$#" -eq 2 ]; then
    case "$2" in
      http://*|https://*) url_override="$2"; url_argument=1 ;;
      *)
        printf 'usage: %s visual-check [dashboard-url]\n' "$0" >&2
        return 64
        ;;
    esac
  fi

  capture_script="${AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT:-$script_dir/../../aiur-meta/scripts/capture-dashboard.mjs}"
  if [ ! -f "$capture_script" ]; then
    printf 'dashboard capture script is unavailable: %s\n' "$capture_script" >&2
    return 66
  fi

  timestamp="$(now_epoch)"
  capture_dir="${AIUR_EXECUTOR_DASHBOARD_CAPTURE_DIR:-${retro_file}.d/dashboard-$timestamp}"
  mkdir -p "$capture_dir"

  discovery="$(AIUR_DASHBOARD_URL="$url_override" dashboard_url 2>/dev/null || true)"
  if [ -n "$discovery" ]; then
    dashboard_base_url="${discovery%%$'\t'*}"
    dashboard_socket="${discovery#*$'\t'}"
    [ "$dashboard_socket" = "$discovery" ] && dashboard_socket=""
  else
    dashboard_base_url=""
    dashboard_socket=""
  fi
  if [ -z "$dashboard_base_url" ]; then
    # Precondition: no dashboard URL to capture. Exit 67 names this exact
    # precondition, the stderr line tells the operator which variable to set,
    # and the verdict says "did not run" so an empty log can never read as a
    # healthy capture.
    capture_status=67
    printf 'AIUR_DASHBOARD_URL is required: could not discover the daemon dashboard URL. Set AIUR_DASHBOARD_URL, or run inside the Aiur tmux session.\n' >&2
    write_did_not_run \
      "$capture_dir" \
      'AIUR_DASHBOARD_URL is not set; no dashboard URL to capture.' \
      'could not discover the daemon dashboard URL; set AIUR_DASHBOARD_URL or run from the Aiur tmux session.' \
      "$dashboard_base_url"
  else
    if [ "$url_argument" -eq 1 ]; then
      url_source="command-line argument"
    elif [ -n "$url_override" ]; then
      url_source="caller override"
    else
      url_source="tmux socket"
    fi
    socket_label="${dashboard_socket:-ambient}"

    # Credentials normally live in the daemon's environment, so the wrapper may
    # not carry them even though the daemon does. Read what the operator would
    # have to extract by hand when the environment is bare — but only when the
    # URL came from a tmux socket, so the read is scoped to the daemon that
    # published it. An operator-set AIUR_DASHBOARD_URL has no socket to scope
    # to, so that path requires the credentials explicitly.
    dashboard_username="${AIUR_DASHBOARD_USERNAME:-}"
    dashboard_password="${AIUR_DASHBOARD_PASSWORD:-}"
    username_source="caller environment"
    password_source="caller environment"
    if [ -n "$dashboard_socket" ]; then
      if [ -z "$dashboard_username" ]; then
        dashboard_username="$(daemon_env_var AIUR_DASHBOARD_USERNAME "$dashboard_socket" || true)"
        [ -z "$dashboard_username" ] || username_source="daemon environment"
      fi
      if [ -z "$dashboard_password" ]; then
        dashboard_password="$(daemon_env_var AIUR_DASHBOARD_PASSWORD "$dashboard_socket" || true)"
        [ -z "$dashboard_password" ] || password_source="daemon environment"
      fi
    fi
    if [ -z "$dashboard_username" ]; then
      dashboard_username="aiur"
      username_source="default"
    fi
    [ -n "$dashboard_password" ] || password_source="unavailable"

    printf 'visual-check sources: dashboard URL=%s (%s); username=%s; password=%s\n' \
      "$url_source" "$socket_label" "$username_source" "$password_source" >&2

    if [ -z "$dashboard_password" ]; then
      # Precondition: the dashboard refuses every request without a password.
      # Exit 69 names this precondition distinctly from a missing URL (67) or
      # an invalid run ID (68).
      capture_status=69
      printf 'AIUR_DASHBOARD_PASSWORD is required: set AIUR_DASHBOARD_USERNAME and AIUR_DASHBOARD_PASSWORD, or run where the daemon environment has them.\n' >&2
      write_did_not_run \
        "$capture_dir" \
        'AIUR_DASHBOARD_PASSWORD is not set; the dashboard refuses all requests without it.' \
        'AIUR_DASHBOARD_PASSWORD is not set and could not be read from the running daemon; set it (with AIUR_DASHBOARD_USERNAME) and retry.' \
        "$dashboard_base_url"
    else
      set +e
      AIUR_DASHBOARD_URL="$dashboard_base_url" \
      AIUR_DASHBOARD_USERNAME="$dashboard_username" \
      AIUR_DASHBOARD_PASSWORD="$dashboard_password" \
        node "$capture_script" "$capture_dir" > "$capture_dir/capture-output.json" 2> "$capture_dir/capture-error.log"
      capture_status=$?
      set -e
    fi
  fi

  verdict="$capture_dir/verdict.md"
  if [ ! -s "$verdict" ]; then
    # A successful browser exit without evidence is still an incomplete check.
    [ "$capture_status" -ne 0 ] || capture_status=70
    cat > "$verdict" <<EOF
# Dashboard visual check

- capture: **attention** — browser check exited with status $capture_status; inspect capture-error.log.

Overall: **attention**. Captures may be incomplete.
EOF
  fi

  acquire_lock
  mkdir -p "$(dirname "$retro_file")"
  {
    printf '### Dashboard visual check %s\n\n' "$(now_iso)"
    sed '1{/^# Dashboard visual check$/d;}' "$verdict"
    printf '\n- Evidence: %s\n\n' "$capture_dir"
  } >> "$retro_file"
  unlock

  if [ "$capture_status" -ne 0 ]; then
    return "$capture_status"
  fi

  cat "$capture_dir/report.json"
}

# Run the read-only CLI probe against this run's explicitly keyed daemon and
# append its compact command/pane evidence to the same durable narrative.
cli_check() {
  local check_script check_dir timestamp check_status report
  [ "$#" -eq 1 ] || {
    printf 'usage: %s cli-check\n' "$0" >&2
    exit 64
  }

  check_script="${AIUR_EXECUTOR_CLI_CHECK_SCRIPT:-$script_dir/executor-cli-check.sh}"
  if [ ! -x "$check_script" ]; then
    printf 'CLI check script is unavailable: %s\n' "$check_script" >&2
    return 66
  fi

  timestamp="$(now_epoch)"
  check_dir="${AIUR_EXECUTOR_CLI_CHECK_DIR:-${retro_file}.d/cli-$timestamp}"
  mkdir -p "$check_dir"

  set +e
  "$check_script" > "$check_dir/report.json" 2> "$check_dir/check-error.log"
  check_status=$?
  set -e

  report="$check_dir/report.json"
  acquire_lock
  mkdir -p "$(dirname "$retro_file")"
  {
    printf '### Interactive CLI check %s\n\n' "$(now_iso)"
    if [ "$check_status" -eq 0 ] && [ -s "$report" ] && jq -e . "$report" >/dev/null 2>&1; then
      jq -r '
        .commands[] |
        "- `aiur \(.command)`: answered=\(.answered), timed_out=\(.timed_out), elapsed_ms=\(.elapsed_ms), non_empty=\(.non_empty), well_formed=\(.well_formed)\n  first_lines: \((.first_lines // []) | join(" | "))"
      ' "$report"
      jq -r '"- Pane surface: session_present=\(.pane_surface.session_present), panes=\(.pane_surface.pane_count // "unknown"), pre_warmed_sessions=\(.pane_surface.pre_warmed_sessions // "unknown"), live_agent_cap=\(.pane_surface.live_agent_cap // "unknown")"' "$report"
      jq -r '"- TUI: mode=\(.tui_surface.mode), expected=\(.tui_surface.expected), attached=\(.tui_surface.attached), agents_row=\(.tui_surface.agents_row), cap_controls=\(.tui_surface.cap_controls)"' "$report"
      if jq -e '.findings | length > 0' "$report" >/dev/null; then
        jq -r '.findings[] | "- Finding: \(.kind) \(.command // "pane") — \(.reason), elapsed_ms=\(.elapsed_ms // "n/a")"' "$report"
      else
        printf '%s\n' '- Findings: none.'
      fi
    else
      printf '%s\n' "- Check: **attention** — CLI probe exited with status $check_status; inspect check-error.log."
    fi
    printf '\n- Evidence: %s\n\n' "$check_dir"
  } >> "$retro_file"
  unlock

  if [ "$check_status" -ne 0 ]; then
    return "$check_status"
  fi

  cat "$report"
}
