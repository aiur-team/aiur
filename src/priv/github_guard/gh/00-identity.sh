# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
#!/bin/sh
# @aiur-recursion-guard@
# Fleet guard for agent-launched `gh` calls. The daemon prepends this wrapper's
# directory to agent PATH and supplies the real executable separately.
# #1793: a ticket filed without a dispatch disposition is undispatchable and
# invisible. The repo PreToolUse hook and the agent-suite tests invoke this
# wrapper in validate-only mode to check a `gh` issue command's disposition
# without requiring a real gh executable or touching any quota/budget state.
validate_only=0
if [ "${1:-}" = --validate-issue-command ]; then
  validate_only=1
  shift
fi

dispatch_prefix=${AIUR_GITHUB_LABEL_PREFIX:-agent}
direct_issue_api=0

real_gh=${AIUR_REAL_GH:-}
is_guard_gh() {
  case "$1" in
    "$HOME/.aiur/bin/gh"|"$HOME/.aiur/github-budget/bin/gh"|*/.aiur-runtime/bin/gh) return 0 ;;
    *) return 1 ;;
  esac
}
if [ -n "$real_gh" ] && is_guard_gh "$real_gh"; then real_gh=; fi
if [ -z "$real_gh" ]; then
  guard_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
  guard_path=${PATH:-}
  guard_old_ifs=$IFS
  IFS=:
  for guard_entry in $guard_path; do
    [ -n "$guard_entry" ] || guard_entry=.
    [ "$guard_entry" = "$guard_dir" ] && continue
    guard_candidate=$guard_entry/gh
    is_guard_gh "$guard_candidate" && continue
    if [ -x "$guard_candidate" ]; then real_gh=$guard_candidate; break; fi
  done
  IFS=$guard_old_ifs
  unset guard_dir guard_path guard_old_ifs guard_entry guard_candidate
fi
if [ "$validate_only" -eq 0 ] && { [ -z "$real_gh" ] || [ ! -x "$real_gh" ]; }; then
  printf '%s\n' 'aiur: real gh executable is unavailable' >&2
  exit 127
fi

state_root=${AIUR_REPO_STATE_PATH:-}
quota_dir=
agent_quota_dir=${AIUR_AGENT_QUOTA_STATE_PATH:-}
events_file=
budget_root=${AIUR_GITHUB_BUDGET_ROOT:-"$HOME/.aiur/github-budget"}
budget_key=${AIUR_GITHUB_BUDGET_KEY:-}
budget_identity_key=${AIUR_GITHUB_BUDGET_IDENTITY_KEY:-}
budget_broker=${AIUR_GITHUB_BUDGET_BROKER:-"$(dirname "$0")/aiur-github-budget"}
budget_requested=${AIUR_GITHUB_BUDGET_ENABLED:-1}
budget_db=
budget_enabled=0
budget_required=0
budget_unavailable_reason=
budget_recovery="budget root $budget_root; repair ownership/permissions and redispatch (current runtimes derive this grant); stale runtimes must add $budget_root to agent.codex.turn_sandbox_policy.writableRoots"
budget_lease=
budget_renewal_pid=
budget_lease_ttl_ms=${AIUR_GITHUB_LEASE_TTL_MS:-35000}
budget_ignore_token_cooldown=0
# Seconds a failed identity derivation stays cached before the next admitted
# call retries it. Bounds an outage to one `gh api user` per credential per
# window instead of one per call (`budget_derive_identity`, #2353 review).
budget_identity_retry_ttl=300
budget_consumer=${AIUR_GITHUB_BUDGET_CONSUMER:-"executor:${PPID:-$$}"}
budget_consumer_key=
# Set when THIS wrapper resolved the credential key from a token rather than
# receiving `AIUR_GITHUB_BUDGET_KEY` from a caller. Only then does it derive the
# credential's stable identity — a caller that already picked the key has made
# the identity decision itself (#2353).
budget_key_derived=0

case "$budget_requested" in
  0|false|FALSE|no|NO|off|OFF) budget_required=0 ;;
  *) [ -n "$budget_root" ] && budget_required=1 ;;
esac
unset budget_requested

# #2356: agents carry no GITHUB_TOKEN/GH_TOKEN (Aiur.AgentEnvironment scrubs
# them). The credential comes from the file the daemon wrote and is injected
# only into the real `gh` child of THIS governed call, never the agent env or
# this wrapper's other children. The env fallback keeps host/Executor working.
guard_token=
if [ -n "${AIUR_GITHUB_CREDENTIAL_FILE:-}" ] && [ -f "$AIUR_GITHUB_CREDENTIAL_FILE" ]; then
  guard_token=$(sed -n '1p' "$AIUR_GITHUB_CREDENTIAL_FILE" 2>/dev/null || true)
fi
[ -n "$guard_token" ] || guard_token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
run_gh() {
  if [ -n "${guard_token:-}" ]; then GH_TOKEN="$guard_token" GITHUB_TOKEN= "$real_gh" "$@"
  else GITHUB_TOKEN= GH_TOKEN= "$real_gh" "$@"; fi
}

fingerprint_value() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# The broker's stable one-way identity for a credential, domain-separated
# exactly as `Aiur.GitHub.Budget.identity_key/1` computes it for a machine
# user: sha256 of `aiur-github-credential-v1<NUL>machine_user:primary:<login>`.
# `\000` is the clear spelling of a NUL byte for POSIX printf, which treats `\0`
# as the start of an octal escape — so `\0` and `\000` produce the identical NUL
# and the hashed input is byte-identical to the Elixir side's
# `aiur-github-credential-v1\0machine_user:primary:<login>` either way.
identity_fingerprint() {
  if command -v shasum >/dev/null 2>&1; then
    printf 'aiur-github-credential-v1\000machine_user:primary:%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf 'aiur-github-credential-v1\000machine_user:primary:%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Derives the credential's stable identity key for a host (non-agent) run that
# resolved its own token. `gh api user` reports the login of whichever
# credential the wrapper resolved (the bot's GITHUB_TOKEN, or the operator's
# keyring account), so the binding matches the token's identity. The derivation
# costs one Core request per new credential and is cached by token key under
# the budget root, so subsequent host calls reuse it.
#
# The derivation runs only for a call that is about to be admitted against a
# metered pool. A local credential read (`auth token`, `config`) must not pay a
# GitHub network round trip just to learn its own identity — the boot gate that
# consults `Config.keyring_token/0` would otherwise block offline, and the
# derivation's own request is unadmitted (#2353 review). A failed derivation is
# cached for `budget_identity_retry_ttl` seconds so an outage is not re-paid per
# call; within the window the call degrades to no identity key — the raw token
# hash is recorded, exactly as today — never to a wrong identity.
budget_derive_identity() {
  [ -n "$budget_key" ] || return 0
  [ -z "$budget_identity_key" ] || return 0
  [ "$budget_key_derived" -eq 1 ] || return 0
  [ "$budget_enabled" -eq 1 ] || return 0
  [ "$admission_required" -eq 1 ] || return 0
  [ "$resource" != none ] || return 0

  identity_cache="$budget_root/identity-$budget_key"
  budget_cached=
  if [ -f "$identity_cache" ]; then
    budget_cached=$(sed -n '1p' "$identity_cache" 2>/dev/null || true)
  fi

  case "$budget_cached" in
    "failed "*) 
      # A failed derivation is cached so an outage costs one `gh api user` per
      # credential per window, not one per call. Once the window ages out, the
      # next admitted call tries again, so a credential that was briefly
      # offline still gets bound once GitHub is reachable.
      budget_failed_at=${budget_cached#failed }
      budget_now=$(date -u +%s 2>/dev/null || printf '')
      if [ -n "$budget_failed_at" ] && [ -n "$budget_now" ] &&
         [ "$budget_failed_at" -ge 0 ] 2>/dev/null && [ "$budget_now" -ge 0 ] 2>/dev/null &&
         [ $((budget_now - budget_failed_at)) -lt $budget_identity_retry_ttl ]; then
        unset budget_cached budget_failed_at budget_now
        return 0
      fi
      unset budget_failed_at budget_now
      ;;
    ''|*[!0-9a-f]*)
      : ;;  # no cache, or a value that is not a hex identity key — re-derive
    *)
      budget_identity_key=$budget_cached
      unset budget_cached
      return 0
      ;;
  esac
  unset budget_cached

  # Routed through `run_gh` (#2356): agents carry no GITHUB_TOKEN/GH_TOKEN, so a
  # direct `$real_gh` call here would go out unauthenticated and derive an empty
  # login, splitting one credential's usage across two identities.
  budget_login=$(run_gh api user --jq .login 2>/dev/null || true)
  # `Aiur.GitHub.Credential.stable_identity/1` downcases every identity part,
  # so the shell derivation must too, or a login with any uppercase character
  # would hash to a different identity key here than on the daemon side and
  # split one credential across two identities in the usage report.
  if command -v tr >/dev/null 2>&1; then
    budget_login=$(printf '%s' "$budget_login" | tr '[:upper:]' '[:lower:]')
  fi
  case "$budget_login" in
    ''|*[!A-Za-z0-9_-]*)
      budget_failed_at=$(date -u +%s 2>/dev/null || printf '')
      case "$budget_failed_at" in
        ''|*[!0-9]*) : ;;
        *) printf 'failed %s\n' "$budget_failed_at" > "$identity_cache" 2>/dev/null || true ;;
      esac
      unset budget_failed_at
      return 0
      ;;
    *)
      budget_identity_key=$(identity_fingerprint "$budget_login") || budget_identity_key=
      if [ -n "$budget_identity_key" ]; then
        printf '%s\n' "$budget_identity_key" > "$identity_cache" 2>/dev/null || true
      fi
      ;;
  esac
  unset budget_login
  return 0
}

# A process under a shifted clock (a libfaketime test worker, #4714) prices every
# hold against the wrong `now`: it publishes holds weeks ahead and deletes the
# fleet's real holds as expired. Such a process keeps no quota state at all.
# `btime + uptime` is the kernel's wall clock, which an LD_PRELOAD shim cannot fake.
# Under lxcfs (`/proc/uptime` virtualized, `btime` from the host) the check can
# misfire. That only drops shared quota coordination for the call, an accepted cost.
clock_shift=
case "${LD_PRELOAD:-}:${DYLD_INSERT_LIBRARIES:-}" in *faketime*) clock_shift='libfaketime is preloaded' ;; esac
if [ -n "${FAKETIME:-}" ]; then clock_shift='FAKETIME is set'; fi
if [ -z "$clock_shift" ] && [ -r /proc/stat ] && [ -r /proc/uptime ]; then
  clock_btime=$(sed -n 's/^btime //p' /proc/stat 2>/dev/null)
  clock_uptime=$(sed -n 's/[. ].*//p' /proc/uptime 2>/dev/null)
  clock_local=$(date -u +%s 2>/dev/null)
  case "$clock_btime:$clock_uptime:$clock_local" in
    *[!0-9:]*|:*|*::*|*:) ;;
    *)
      clock_skew=$((clock_local - clock_btime - clock_uptime))
      if [ "${clock_skew#-}" -gt 300 ]; then clock_shift="local clock is ${clock_skew}s off the kernel clock"; fi
      ;;
  esac
  unset clock_btime clock_uptime clock_local clock_skew
fi
if [ -n "$clock_shift" ]; then
  printf 'aiur: %s; ignoring shared GitHub quota state for this call\n' "$clock_shift" >&2
  state_root=
  agent_quota_dir=
  # The broker DB is shared hold state too, priced by an equally shifted clock.
  budget_required=0
fi

if [ -n "$state_root" ]; then
  quota_dir=$state_root/github-quota
  mkdir -p "$quota_dir" 2>/dev/null || true
fi

if [ -z "$agent_quota_dir" ]; then agent_quota_dir=$quota_dir; fi
if [ -n "$agent_quota_dir" ]; then
  events_file=$agent_quota_dir/agent-requests.tsv
  mkdir -p "$agent_quota_dir" 2>/dev/null || true
fi

if [ "$budget_required" -eq 1 ]; then
  if [ -z "$budget_broker" ] || [ ! -x "$budget_broker" ]; then
    budget_unavailable_reason='broker executable is unavailable'
  elif ! command -v python3 >/dev/null 2>&1; then
    budget_unavailable_reason='python3 is unavailable'
  elif ! mkdir -p "$budget_root" 2>/dev/null; then
    budget_unavailable_reason='state directory is unavailable'
  else
    if [ -z "$budget_key" ]; then
      # `guard_token` is the file credential (agents) or the inherited env
      # token (host/Executor); the keyring read below feeds both too.
      budget_token=$guard_token
      if [ -z "$budget_token" ]; then
        budget_token=$(GITHUB_TOKEN= GH_TOKEN= "$real_gh" auth token --hostname github.com 2>/dev/null || true)
        [ -n "$budget_token" ] && guard_token=$budget_token
      fi

      if [ -z "$budget_token" ]; then
        budget_unavailable_reason='GitHub credential is unavailable'
      else
        budget_key=$(fingerprint_value "$budget_token") || budget_key=
        [ -n "$budget_key" ] || budget_unavailable_reason='credential fingerprint is unavailable'
        budget_key_derived=1
      fi
      unset budget_token
    fi

    if [ -z "$budget_unavailable_reason" ]; then
      budget_db=$budget_root/budget.sqlite3
      budget_enabled=1
    fi
  fi
fi

if [ "$budget_enabled" -eq 1 ]; then
  budget_consumer_key=$(fingerprint_value "$budget_consumer") || budget_consumer_key=
  [ -n "$budget_consumer_key" ] || budget_consumer_key=shared
fi
# The raw identity is the human-readable actor label for the usage report; the
# consumer key above stays a fingerprint. Preserved separately so `usage` can
# name this caller even when AIUR_GITHUB_BUDGET_CONSUMER is not exported.
budget_consumer_label=${AIUR_GITHUB_BUDGET_CONSUMER:-"executor:${PPID:-$$}"}
unset budget_consumer

