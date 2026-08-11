#!/bin/sh

# Fleet guard for agent-launched `gh` calls. The daemon prepends this wrapper's
# directory to agent PATH and supplies the real executable separately.
real_gh=${AIUR_REAL_GH:-}
if [ -z "$real_gh" ]; then
  guard_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
  guard_path=${PATH:-}
  guard_old_ifs=$IFS
  IFS=:
  for guard_entry in $guard_path; do
    [ -n "$guard_entry" ] || guard_entry=.
    [ "$guard_entry" = "$guard_dir" ] && continue
    guard_candidate=$guard_entry/gh
    if [ -x "$guard_candidate" ]; then real_gh=$guard_candidate; break; fi
  done
  IFS=$guard_old_ifs
  unset guard_dir guard_path guard_old_ifs guard_entry guard_candidate
fi
if [ -z "$real_gh" ] || [ ! -x "$real_gh" ]; then
  printf '%s\n' 'aiur: real gh executable is unavailable' >&2
  exit 127
fi

state_root=${AIUR_REPO_STATE_PATH:-}
quota_dir=
agent_quota_dir=${AIUR_AGENT_QUOTA_STATE_PATH:-}
events_file=
budget_root=${AIUR_GITHUB_BUDGET_ROOT:-"$HOME/.aiur/github-budget"}
budget_key=${AIUR_GITHUB_BUDGET_KEY:-}
budget_broker=${AIUR_GITHUB_BUDGET_BROKER:-"$(dirname "$0")/aiur-github-budget"}
budget_db=
budget_enabled=0
budget_lease=

if [ -n "$state_root" ]; then
  quota_dir=$state_root/github-quota
  mkdir -p "$quota_dir" 2>/dev/null || true
fi

if [ -z "$agent_quota_dir" ]; then agent_quota_dir=$quota_dir; fi
if [ -n "$agent_quota_dir" ]; then
  events_file=$agent_quota_dir/agent-requests.tsv
  mkdir -p "$agent_quota_dir" 2>/dev/null || true
fi

if [ -n "$budget_root" ] && [ -n "$budget_key" ] && [ -n "$budget_broker" ] && [ -x "$budget_broker" ]; then
  if mkdir -p "$budget_root" 2>/dev/null && command -v python3 >/dev/null 2>&1; then
    budget_db=$budget_root/budget.sqlite3
    budget_enabled=1
  fi
fi

if [ "$budget_enabled" -eq 0 ] && [ -x "$budget_broker" ]; then
  budget_token=${GITHUB_TOKEN:-}
  if [ -z "$budget_token" ]; then
    budget_token=$(GITHUB_TOKEN= GH_TOKEN= "$real_gh" auth token --hostname github.com 2>/dev/null || true)
  fi

  if [ -n "$budget_token" ] && budget_key=$(printf '%s' "$budget_token" | sha256sum 2>/dev/null | awk '{print $1}') && [ -n "$budget_key" ]; then
    if mkdir -p "$budget_root" 2>/dev/null && command -v python3 >/dev/null 2>&1; then
      budget_db=$budget_root/budget.sqlite3
      budget_enabled=1
    fi
  fi
  unset budget_token
fi

direction=read
track=1
resource=unknown
endpoint_family=rest

case "${1:-} ${2:-}" in
  "api rate_limit") resource=none ;;
  "api graphql"|"api /graphql")
    resource=graphql
    endpoint_family=graphql
    for arg in "$@"; do
      case "$arg" in *mutation*|*Mutation*) direction=write ;; esac
    done
    ;;
  "api "*)
    resource=core
    endpoint=${2#/}
    endpoint=${endpoint#repos/}
    case "$endpoint" in
      */*/*) endpoint_family=$(printf '%s' "$endpoint" | cut -d/ -f3) ;;
      *) endpoint_family=rest ;;
    esac
    prior=
    for arg in "$@"; do
      if [ "$prior" = -X ] || [ "$prior" = --method ]; then
        case "$arg" in GET|get) ;; *) direction=write ;; esac
      fi
      case "$arg" in
        -XPOST|-XPATCH|-XPUT|-XDELETE|--method=POST|--method=PATCH|--method=PUT|--method=DELETE|-f|-F|--field|--raw-field|--field=*|--raw-field=*) direction=write ;;
      esac
      prior=$arg
    done
    ;;
  "pr view"|"pr list"|"pr status"|"pr checks"|"pr diff") endpoint_family=pulls ;;
  "issue view"|"issue list"|"issue status") endpoint_family=issues ;;
  "run view"|"run list"|"run watch") endpoint_family=actions ;;
  "search "*) endpoint_family=search ;;
  "pr "*) endpoint_family=pulls; direction=write ;;
  "issue "*) endpoint_family=issues; direction=write ;;
  "run rerun"|"run cancel"|"run delete") endpoint_family=actions; direction=write ;;
  "label create"|"label delete"|"label edit") endpoint_family=labels; direction=write ;;
  "config "*|"alias "*|"completion "*|"help "*|"version "*) track=0; resource=none ;;
  "auth "*|"extension "*) track=0 ;;
esac

consumer=unattributed
if [ -n "${AIUR_AGENT_WORKSPACE:-}" ]; then
  ticket=$(basename "$AIUR_AGENT_WORKSPACE")
  case "$ticket" in
    ''|*[!0-9]*) ;;
    *) consumer=ticket:$ticket ;;
  esac
fi

budget_command() {
  python3 "$budget_broker" "$@" --db "$budget_db" --token-key "$budget_key"
}

budget_sleep_ms() {
  budget_delay=$1
  case "$budget_delay" in ''|*[!0-9]*) return 1 ;; esac
  budget_seconds=$(awk "BEGIN { printf \"%.3f\", $budget_delay / 1000 }")
  sleep "$budget_seconds"
}

budget_acquire() {
  [ "$budget_enabled" -eq 1 ] || return 0

  while :; do
    budget_result=$(budget_command acquire --resource "$resource" --endpoint-family "$endpoint_family" \
      --max-inflight "${AIUR_GITHUB_MAX_INFLIGHT:-4}" \
      --max-inflight-per-endpoint "${AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT:-2}" \
      --requests-per-minute "${AIUR_GITHUB_REQUESTS_PER_MINUTE:-120}" \
      --stagger-ms "${AIUR_GITHUB_STAGGER_MS:-75}" --lease-ttl-ms 35000 2>/dev/null) || return 0

    case "$budget_result" in
      "granted "*) budget_lease=${budget_result#granted }; return 0 ;;
      "wait "*) budget_sleep_ms "${budget_result#wait }" || return 0 ;;
      *) return 0 ;;
    esac
  done
}

budget_release() {
  [ -n "$budget_lease" ] || return 0
  budget_command release --lease-id "$budget_lease" >/dev/null 2>&1 || true
  budget_lease=
}

budget_hold() {
  budget_scope=$1
  budget_delay=$2
  budget_resource=${3:-$resource}
  [ "$budget_enabled" -eq 1 ] || return 0
  budget_command hold --scope "$budget_scope" --resource "$budget_resource" --delay-ms "$budget_delay" >/dev/null 2>&1 || true
}

secondary_delay_ms() {
  retry_after=$(sed -n -E 's/^[[:space:]]*[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*([0-9]+).*/\1/p' "$1" | sed -n '1p')

  case "$retry_after" in
    ''|0|*[!0-9]*) printf '%s\n' 60000 ;;
    *)
      if [ "$retry_after" -gt 3600 ]; then retry_after=3600; fi
      printf '%s\n' $((retry_after * 1000))
      ;;
  esac
}

now=$(date -u +%s)
hold_until=0

consider_hold() {
  candidate=$(sed -n '1p' "$1" 2>/dev/null)
  case "$candidate" in
    ''|*[!0-9]*) return ;;
  esac

  if [ "$candidate" -gt "$now" ]; then
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
    core|graphql)
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

if [ "$resource" != none ] && [ -n "$quota_dir" ]; then
  consider_resource_holds "$quota_dir" "$resource"
fi

if [ "$resource" != none ] && [ -n "$agent_quota_dir" ] && [ "$agent_quota_dir" != "$quota_dir" ]; then
  consider_resource_holds "$agent_quota_dir" "$resource"
fi

if [ "$hold_until" -gt "$now" ]; then
  delay=$((hold_until - now))
  printf 'aiur: GitHub quota backoff; waiting %ss until %s\n' "$delay" "$(date -u -d "@$hold_until" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$hold_until")" >&2
  sleep "$delay"
  now=$(date -u +%s)
fi

if [ "$resource" != none ]; then budget_acquire; fi

if [ "$track" -eq 1 ] && [ -n "$events_file" ]; then
  size=0
  if [ -f "$events_file" ]; then size=$(wc -c < "$events_file" 2>/dev/null || printf '0'); fi
  case "$size" in
    ''|*[!0-9]*) size=0 ;;
  esac
  if [ "$size" -gt 1048576 ]; then mv -f "$events_file" "$events_file.1" 2>/dev/null || true; fi

  # The resource column tells the daemon which budget the call was billed to.
  # Without it every agent call was counted against core, and a GraphQL query —
  # billed in points against a separate budget — landed in the wrong window.
  track_resource=$resource
  case "$track_resource" in
    core|graphql) ;;
    *) track_resource=core ;;
  esac

  printf '%s\t%s\t%s\t%s\n' "$now" "$consumer" "$direction" "$track_resource" >> "$events_file" 2>/dev/null || true
fi

error_file=
if [ "$resource" != none ]; then
  old_umask=$(umask)
  umask 077
  error_file=$(mktemp "${TMPDIR:-/tmp}/aiur-gh-stderr.XXXXXX" 2>/dev/null || true)
  umask "$old_umask"
fi

if [ -n "$error_file" ]; then
  "$real_gh" "$@" 2> "$error_file"
  status=$?
  while IFS= read -r line || [ -n "$line" ]; do printf '%s\n' "$line" >&2; done < "$error_file"
else
  "$real_gh" "$@"
  status=$?
fi

if [ "$status" -ne 0 ] && [ -n "$error_file" ] && grep -Eiq 'rate.?limit|rate_limit' "$error_file" && { [ -n "$agent_quota_dir" ] || [ "$budget_enabled" -eq 1 ]; }; then
  observation=$("$real_gh" api rate_limit --template '{{.resources.core.remaining}} {{.resources.core.reset}} {{.resources.graphql.remaining}} {{.resources.graphql.reset}}' 2>/dev/null || true)
  set -- $observation
  exhausted=0

  if [ "$#" -eq 4 ]; then
    core_remaining=$1
    core_reset=$2
    graphql_remaining=$3
    graphql_reset=$4

    case "$core_remaining:$core_reset" in
      0:[0-9]*)
        if [ -n "$agent_quota_dir" ]; then printf '%s\n' "$core_reset" > "$agent_quota_dir/core-hold" 2>/dev/null || true; fi
        budget_delay=$(( (core_reset - $(date -u +%s)) * 1000 ))
        if [ "$budget_delay" -gt 0 ]; then budget_hold resource "$budget_delay" core; fi
        exhausted=1
        ;;
    esac
    case "$graphql_remaining:$graphql_reset" in
      0:[0-9]*)
        if [ -n "$agent_quota_dir" ]; then printf '%s\n' "$graphql_reset" > "$agent_quota_dir/graphql-hold" 2>/dev/null || true; fi
        budget_delay=$(( (graphql_reset - $(date -u +%s)) * 1000 ))
        if [ "$budget_delay" -gt 0 ]; then budget_hold resource "$budget_delay" graphql; fi
        exhausted=1
        ;;
    esac

    if [ "$exhausted" -eq 1 ]; then
      printf '%s\n' 'aiur: GitHub quota exhausted; exact reset backoff recorded' >&2
    fi
  fi

  # A rate-limit refusal while both primary windows still read healthy is a
  # secondary (abuse) limit. Nothing in the primary windows records it, so
  # without its own backoff the next call retries straight into another
  # rejection. Honour Retry-After when gh exposes it, with GitHub's 60-second
  # guidance as the fallback.
  if [ "$exhausted" -eq 0 ]; then
    secondary_delay=$(secondary_delay_ms "$error_file")
    secondary_wait_seconds=$(( (secondary_delay + 999) / 1000 ))
    secondary_until=$(( $(date -u +%s) + secondary_wait_seconds ))

    case "$resource" in
      core|graphql) if [ -n "$agent_quota_dir" ]; then printf '%s\n' "$secondary_until" > "$agent_quota_dir/$resource-secondary-hold" 2>/dev/null || true; fi ;;
      *)
        if [ -n "$agent_quota_dir" ]; then
          printf '%s\n' "$secondary_until" > "$agent_quota_dir/core-secondary-hold" 2>/dev/null || true
          printf '%s\n' "$secondary_until" > "$agent_quota_dir/graphql-secondary-hold" 2>/dev/null || true
        fi
        ;;
    esac

    printf 'aiur: GitHub secondary rate limit; backing off %ss before the next call\n' "$secondary_wait_seconds" >&2
    budget_hold token "$secondary_delay"
  fi
fi

budget_release
if [ -n "$error_file" ]; then rm -f "$error_file" 2>/dev/null || true; fi
exit "$status"
