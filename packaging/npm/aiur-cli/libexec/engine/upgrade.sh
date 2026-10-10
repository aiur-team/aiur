# Upgrade version notice and `aiur upgrade`. Sourced by aiur-engine.sh.

# --- upgrade version notice + aiur upgrade -----------------------------------

# Extract a top-level string field from a JSON document. The notice keys we
# read (`text`, `available`, `channel`, `channel_gone`) are unique to the
# notice, and the dist-tags keys we read are the tag names themselves, so a
# plain sed over the document is unambiguous. Handles both quoted strings
# (`"channel":"nightly"`) and unquoted scalars (`"channel_gone":true`,
# `"available":null`) — the state file serializes booleans/null without quotes.
upgrade_state_string() {
  local file="$1" key="$2"
  sed -n "s/.*\"$key\": *\"\([^\"]*\)\".*/\1/p; s/.*\"$key\": *\([^,}]*\).*/\1/p" "$file" | head -n 1
}

# Atomically write the "last told" marker (a single line). The engine owns this
# file; the daemon only reads it for its no-repeat decision. Best-effort and
# always succeeds (returns 0) so a read-only/unwritable state dir can never
# abort the caller — the notice display and `aiur upgrade` must not fail
# because a marker could not be written.
upgrade_state_mark_notified() {
  local value="$1" file="$AIUR_BG_STATE_DIR/upgrade-notified.txt" tmp
  mkdir -p "$AIUR_BG_STATE_DIR" 2>/dev/null || return 0
  tmp="$(mktemp "$AIUR_BG_STATE_DIR/upgrade-notified.XXXXXX" 2>/dev/null)" || return 0
  printf '%s\n' "$value" >"$tmp" 2>/dev/null
  mv -f "$tmp" "$file" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# Surface the pending upgrade notice, if any, to the operator's terminal. This
# is a cheap local state read (the daemon's `Aiur.Upgrade` check writes it
# during boot) — never the registry — so it can never delay startup. It honors
# the same opt-outs as the check, prints only once per version (the `notified`
# marker), and is completely silent under a development launcher.
maybe_surface_upgrade_notice() {
  aiur_resolve_identity

  # A development launcher (aiurdev) must never suggest an upgrade: the notice
  # would be wrong (the local tree is routinely ahead of every published
  # version) and acting on it would overwrite a working tree. Detect the
  # launcher, never the directory — an installed aiur can be run from inside a
  # clone and still deserves its notice.
  case "${AIUR_RELEASE_DIR:-}" in
    */src/_build/dev/rel/aiur) return 0 ;;
  esac

  # Env opt-outs, mirroring Aiur.Upgrade.disabled?/0.
  case "${AIUR_UPGRADE_CHECK_DISABLED:-}" in 1 | true) return 0 ;; esac
  case "${AIUR_NO_UPDATE_NOTIFIER:-}" in 1 | true) return 0 ;; esac
  case "${CI:-}" in "" | false | 0) ;; *) return 0 ;; esac

  # Interactive gate: never print into a piped or non-TTY stream.
  [ -t 2 ] || return 0

  maybe_print_upgrade_notice
}

# The display half of the notice: read the daemon-written state, decide whether
# the operator has already been told this version, print it to stderr, and mark
# it told. Split from `maybe_surface_upgrade_notice` (the env/CI/dev/TTY gates)
# so the print/decide logic is testable without a pty.
maybe_print_upgrade_notice() {
  local state_file="$AIUR_BG_STATE_DIR/upgrade.json"
  [ -r "$state_file" ] || return 0

  local text available channel channel_gone notified installed
  text="$(upgrade_state_string "$state_file" text)"
  [ -n "$text" ] || return 0
  available="$(upgrade_state_string "$state_file" available)"
  channel="$(upgrade_state_string "$state_file" channel)"
  channel_gone="$(upgrade_state_string "$state_file" channel_gone)"
  notified="$(cat "$AIUR_BG_STATE_DIR/upgrade-notified.txt" 2>/dev/null || true)"
  installed="$(cli_package_version || true)"

  if [ "$channel_gone" = "true" ]; then
    # A "channel no longer publishes" notice: say it once, never nag.
    [ -n "$channel" ] && [ "$notified" = "gone:${channel}" ] && return 0
    printf '%s\n' "$text" >&2
    upgrade_state_mark_notified "gone:${channel}"
    return 0
  fi

  # A normal notice: only when it is genuinely newer than what is installed
  # (never a downgrade) and the operator has not already been told this exact
  # version.
  [ -n "$available" ] || return 0
  [ -n "$installed" ] || return 0
  version_is_older "$installed" "$available" || return 0
  if [ -n "$notified" ] && ! version_is_older "$notified" "$available"; then
    return 0
  fi

  printf '%s\n' "$text" >&2
  upgrade_state_mark_notified "$available"
}

# Detect how this `aiur` was installed from the launcher-resolved release dir
# and the package layout — never from the working directory, so an installed
# aiur run from inside a clone is still recognized as an npm install.
aiur_install_method() {
  case "${AIUR_RELEASE_DIR:-}" in
    */src/_build/dev/rel/aiur)
      printf 'dev'
      return
      ;;
  esac
  if command -v brew >/dev/null 2>&1 && brew list aiur >/dev/null 2>&1; then
    printf 'brew'
    return
  fi
  if [ -r "$engine_dir/../package.json" ]; then
    printf 'npm'
    return
  fi
  printf 'unknown'
}

# `aiur upgrade` — installs the newer aiur-cli on the user's channel and
# reports what it did. Refuses in a development checkout (nothing to install,
# tree must stay untouched), refuses Homebrew/unknown installs (aiur releases
# are npm-only right now), refuses while a daemon is running unless --force,
# never downgrades across channels, and reports before/after versions with the
# restart step needed to actually pick the new code up.
cmd_upgrade() {
  local force=0 arg
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      *) echo "aiur: upgrade accepts only --force" >&2; exit 64 ;;
    esac
  done

  aiur_resolve_identity

  case "$(aiur_install_method)" in
    dev)
      die "aiur upgrade cannot run from a development checkout (aiurdev): the local tree is not a published install, so upgrade would not touch this working tree and nothing has been changed. Install aiur from npm and run \`aiur upgrade\` from the installed CLI."
      ;;
    brew)
      die "aiur upgrade does not support Homebrew installs: aiur releases are npm-only right now (the Homebrew tap is not fed by releases). Reinstall from npm (\`npm install -g aiur-cli\`) and use \`aiur upgrade\` there."
      ;;
    unknown)
      die "aiur could not determine how it was installed, so upgrade refused to guess. Reinstall from npm (\`npm install -g aiur-cli\`) and retry."
      ;;
  esac

  resolve_release
  prepare_distribution || die "distribution setup failed; cannot check for a running daemon"

  # Do not swap the binary underneath a running daemon or a live fleet.
  if [ "$(probe_control_liveness)" = "up" ]; then
    if [ "$force" -ne 1 ]; then
      echo "❌ aiur is running. \`aiur upgrade\` refuses to replace the binary under a live daemon." >&2
      echo "   Stop it first (\`aiur stop\`), upgrade, then start again; or pass --force to upgrade" >&2
      echo "   anyway. With --force the running daemon keeps the old code until restarted, and" >&2
      echo "   in-flight agents are unaffected until then." >&2
      exit 64
    fi
    echo "⚠️  aiur is running; --force upgrades anyway. The running daemon keeps the old" >&2
    echo "   code until you restart it — in-flight agents are unaffected until then." >&2
  fi

  local before after channel available tags latest next nightly
  before="$(cli_package_version || true)"
  [ -n "$before" ] || die "aiur could not read the installed version; upgrade aborted"

  if ! tags="$(npm view aiur-cli dist-tags --json 2>/dev/null)"; then
    die "aiur could not reach the npm registry to determine available versions (is npm installed and online?); upgrade aborted"
  fi

  # Resolve the user's channel from the installed version AND the observed
  # dist-tags, mirroring Aiur.Upgrade.channel/2. A `next` user must never be
  # measured against (or "upgraded" to) `latest` when that is lower — today
  # latest=0.0.3, next=0.0.4, nightly=0.0.5-nightly.<sha>.
  case "$before" in
    *-nightly*)
      channel="nightly"
      ;;
    *)
      next="$(upgrade_state_string <(printf '%s' "$tags") next || true)"
      latest="$(upgrade_state_string <(printf '%s' "$tags") latest || true)"
      if [ -n "$next" ] &&
        { [ "$before" = "$next" ] ||
          { [ -n "$latest" ] && version_is_older "$before" "$next" && version_is_older "$latest" "$before"; }; }; then
        channel="next"
      else
        channel="latest"
      fi
      ;;
  esac

  available="$(upgrade_state_string <(printf '%s' "$tags") "$channel" || true)"
  if [ -z "$available" ]; then
    echo "❌ the ${channel} channel no longer publishes new versions (installed ${before})." >&2
    echo "   aiur upgrade will not silently fall back to another channel." >&2
    exit 64
  fi

  if ! version_is_older "$before" "$available"; then
    echo "aiur is already up to date on the ${channel} channel (${before})." >&2
    return 0
  fi

  echo "aiur: upgrading aiur-cli from ${before} to ${available} on the ${channel} channel..." >&2
  if ! npm install -g "aiur-cli@${channel}" --no-offline --no-prefer-offline; then
    die "aiur upgrade failed during \`npm install -g aiur-cli@${channel}\`; the installed version is unchanged"
  fi

  after="$(cli_package_version || true)"
  if [ -n "$after" ] && [ "$after" != "$before" ]; then
    echo "aiur upgraded from ${before} to ${after}." >&2
  else
    echo "aiur upgraded on the ${channel} channel (was ${before})." >&2
  fi

  # Never re-offer the version just installed.
  upgrade_state_mark_notified "$after"
  echo "Restart any running aiur to pick up the new version." >&2
}
