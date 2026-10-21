# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
# `marker_cleanup` is defined and armed beside the marker block itself, so the
# early refusal exits do not leak a temp copy. On a signal, stop lease renewal
# without synchronously calling a broker that may be the command being killed;
# the lease stays counted until its TTL expires.
trap 'stop_interruptible_sleep; marker_cleanup; budget_stop_renewal; trap - 0; exit 143' HUP INT TERM
trap 'marker_cleanup; budget_release' 0

secondary_delay_ms() {
  retry_after=
  for retry_source in "$@"; do
    [ -n "$retry_source" ] && [ -f "$retry_source" ] || continue
    retry_after=$(sed -n -E 's/^[[:space:]]*[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*([0-9]+).*/\1/p' "$retry_source" | sed -n '1p')
    [ -n "$retry_after" ] && break
  done

  case "$retry_after" in
    ''|0|*[!0-9]*) printf '%s\n' 60000 ;;
    *)
      if [ "$retry_after" -gt 3600 ]; then retry_after=3600; fi
      printf '%s\n' $((retry_after * 1000))
      ;;
  esac
}

# Reuse the timestamp the cache section already sampled rather than forking
# `date` a second time; they are the same instant for every purpose here.
now=${cache_started_at:-}
case "$now" in
  ''|*[!0-9]*) now=$(date -u +%s) ;;
esac
hold_until=0

# A truncating `>` redirect leaves the hold file empty between truncate and
# write. A concurrent reader sampling it in that gap sees no hold, `consider_hold`
# bails, and the call goes out during an exhausted window. Writing to a sibling
# temp file and renaming makes the hold appear in one step — the same reason the
# Elixir side uses temp+rename in `Aiur.AgentGitHubGuard.write_hold_file/3`.
write_hold() {
  write_hold_tmp="$1.tmp.$$"

  if printf '%s\n' "$2" > "$write_hold_tmp" 2>/dev/null; then
    mv -f "$write_hold_tmp" "$1" 2>/dev/null || rm -f "$write_hold_tmp" 2>/dev/null || true
  else
    rm -f "$write_hold_tmp" 2>/dev/null || true
  fi

  return 0
}

# Exhaustion an agent discovers first is fleet-wide news, but holds used to be
# written only to the per-workspace dir no other agent and not the daemon reads
# — so everyone else rediscovered it on the daemon's next `/rate_limit` probe.
# Reads already consult both dirs (`consider_resource_holds` below), so writes
# publish to both too; an unwritable shared dir fails quietly and leaves the
# workspace hold in place.
#
# A primary window resets within an hour and a secondary limit lasts minutes,
# so a deadline past `hold_max_ahead` is corrupt (a skewed clock or a test
# fixture) and would park the whole fleet until it expires (#4698). Writers
# refuse it; readers ignore it and leave it for the daemon to remove and alert.
# An empty state path publishes nothing and never falls back to `~/.aiur`.
hold_max_ahead=3660

publish_hold() {
  if [ "$2" -gt $(( $(date -u +%s) + hold_max_ahead )) ]; then
    printf 'aiur: refusing implausible %s until %s (more than %ss ahead)\n' "$1" "$2" "$hold_max_ahead" >&2
    return 0
  fi

  if [ -n "$agent_quota_dir" ]; then write_hold "$agent_quota_dir/$1" "$2"; fi

  if [ -n "$quota_dir" ] && [ "$quota_dir" != "$agent_quota_dir" ]; then
    write_hold "$quota_dir/$1" "$2"
  fi

  return 0
}

consider_hold() {
  candidate=$(sed -n '1p' "$1" 2>/dev/null)
  case "$candidate" in
    ''|*[!0-9]*) return ;;
  esac

  if [ "$candidate" -gt $((now + hold_max_ahead)) ]; then
    printf 'aiur: ignoring implausible hold %s until %s\n' "$1" "$candidate" >&2
  elif [ "$candidate" -gt "$now" ]; then
    if [ "$candidate" -gt "$hold_until" ]; then hold_until=$candidate; fi
  else
    rm -f "$1" 2>/dev/null || true
  fi
}

# Both hold kinds gate a call: `-hold` is the exhausted primary window, and
# `-secondary-hold` is a secondary/abuse-limit backoff, which GitHub raises
# while the primary window still reads healthy.
consider_resource_holds() {
  case "$2" in
    core|graphql|search)
      consider_hold "$1/$2-hold"
      consider_hold "$1/$2-secondary-hold"
      ;;
    *)
      consider_hold "$1/core-hold"
      consider_hold "$1/core-secondary-hold"
      consider_hold "$1/graphql-hold"
      consider_hold "$1/graphql-secondary-hold"
      ;;
  esac
}

# The high-level list commands keep their own pagination loop inside one `gh`
# process. A shell guard cannot admit those hidden HTTP pages individually, so
# never let an invocation request more than one GitHub page under one lease.
# `gh api --paginate` is handled above and remains the supported path for
# callers that need more than GitHub's maximum 100-item page.
native_page_limit_exceeds_single_request() {
  [ "${1:-}" != api ] || return 1

  native_limit=
  native_expect_limit=0
  native_options=1

  for native_argument in "$@"; do
    [ "$native_options" -eq 1 ] || continue

    if [ "$native_expect_limit" -eq 1 ]; then
      native_limit=$native_argument
      native_expect_limit=0
      continue
    fi

    case "$native_argument" in
      --) native_options=0 ;;
      --limit|-L) native_expect_limit=1 ;;
      --limit=*) native_limit=${native_argument#--limit=} ;;
      -L*) native_limit=${native_argument#-L} ;;
    esac
  done

  case "$native_limit" in
    ''|*[!0-9]*) return 1 ;;
  esac

  [ "$native_limit" -gt "${AIUR_GITHUB_NATIVE_PAGE_SIZE:-100}" ]
}

if [ "$resource" != none ] && [ "$budget_enabled" -eq 1 ] && native_page_limit_exceeds_single_request "$@"; then
  printf '%s\n' 'aiur: guarded high-level gh commands cannot fetch more than one page; use gh api --paginate for budgeted multi-page reads' >&2
  exit 64
fi

if [ "$resource" != none ] && [ -n "$quota_dir" ]; then
  consider_resource_holds "$quota_dir" "$resource"
fi

if [ "$resource" != none ] && [ -n "$agent_quota_dir" ] && [ "$agent_quota_dir" != "$quota_dir" ]; then
  consider_resource_holds "$agent_quota_dir" "$resource"
fi

if [ "$hold_until" -gt "$now" ]; then
  delay=$((hold_until - now))
  printf 'aiur: GitHub quota backoff; waiting %ss until %s\n' "$delay" "$(date -u -d "@$hold_until" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$hold_until")" >&2
  interruptible_sleep "$delay"
  now=$(date -u +%s)
fi

if [ "$admission_required" -eq 1 ]; then
  if [ "$api_paginated" -eq 1 ] && [ "$budget_enabled" -eq 1 ]; then
    run_budgeted_paginated_api "$@"
    exit $?
  fi
  budget_acquire
  budget_admission=$?
  if [ "$budget_admission" -eq 0 ]; then
    budget_start_renewal
  elif [ "$cache_served" -eq 1 ]; then
    # Another agent's identical fetch answered this one while it waited. The
    # answer is already on stdout and no request was made.
    exit 0
  else
    exit "$budget_admission"
  fi
  unset budget_admission
fi

if [ "$track" -eq 1 ] && [ -n "$events_file" ]; then
  size=0
  if [ -f "$events_file" ]; then size=$(wc -c < "$events_file" 2>/dev/null || printf '0'); fi
  case "$size" in
    ''|*[!0-9]*) size=0 ;;
  esac
  # Retention (#2255): keep the previous two generations so the agent-side
  # request record survives the whole detection latency of a budget anomaly
  # (hours), not just the rolling hour the broker's `admissions` table keeps.
  if [ "$size" -gt 1048576 ]; then
    if [ -f "$events_file.1" ]; then mv -f "$events_file.1" "$events_file.2" 2>/dev/null || true; fi
    mv -f "$events_file" "$events_file.1" 2>/dev/null || true
  fi

  # The resource column tells the daemon which budget the call was billed to.
  # Without it every agent call was counted against core, and a GraphQL query —
  # billed in points against a separate budget — landed in the wrong window.
  track_resource=$resource
  case "$track_resource" in
    core|graphql|search) ;;
    *) track_resource=core ;;
  esac

  # Call-site column: allowlisted subcommand, never raw argv (falls back safe).
  case "$command_name" in
    ''|*[!a-zA-Z0-9-_]*) command_name= ;;
  esac
  case "$subcommand_name" in
    ''|*[!a-zA-Z0-9-_]*) subcommand_name= ;;
  esac
  call_site=${command_name:-gh}
  case "$command_name" in
    api)
      case "$resource" in
        graphql) call_site="api graphql" ;;
        *) call_site=api ;;
      esac
      ;;
    pr|issue|run|search|label)
      case "$subcommand_name" in
        view|list|status|checks|diff|create|merge|review|close|reopen|edit|ready|delete|comment|update-branch|lock|unlock|pin|unpin|transfer|watch|rerun|cancel|issues|prs|repos|code|commits|users) call_site="$command_name $subcommand_name" ;;
      esac
      ;;
  esac

  # The token fingerprint (never the token) answers "which pool did this bill"
  # without a live /proc sweep, and the wrapper pid lets the daemon correlate
  # the call with the subprocess-spawn log of the ticket that made it (#2255).
  # Both are best-effort: an empty fingerprint (budget disabled) or a blank
  # column degrades to an unattributed row, never a refused call. The call-site
  # column sits between the resource and the fingerprint (#2299).
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$consumer" "$direction" "$track_resource" "$call_site" "${budget_key:-}" "$$" >> "$events_file" 2>/dev/null || true
fi
