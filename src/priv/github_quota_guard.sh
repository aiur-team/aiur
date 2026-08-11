#!/bin/sh

# Fleet guard for agent-launched `gh` calls. The daemon prepends this wrapper's
# directory to agent PATH and supplies the real executable separately.
real_gh=${AIUR_REAL_GH:-}
if [ -z "$real_gh" ] || [ ! -x "$real_gh" ]; then
  printf '%s\n' 'aiur: real gh executable is unavailable' >&2
  exit 127
fi

state_root=${AIUR_REPO_STATE_PATH:-}
quota_dir=
agent_quota_dir=${AIUR_AGENT_QUOTA_STATE_PATH:-}
events_file=

if [ -n "$state_root" ]; then
  quota_dir=$state_root/github-quota
  mkdir -p "$quota_dir" 2>/dev/null || true
fi

if [ -z "$agent_quota_dir" ]; then agent_quota_dir=$quota_dir; fi
if [ -n "$agent_quota_dir" ]; then
  events_file=$agent_quota_dir/agent-requests.tsv
  mkdir -p "$agent_quota_dir" 2>/dev/null || true
fi

direction=read
track=1
resource=unknown

case "${1:-} ${2:-}" in
  "api rate_limit") resource=none ;;
  "api graphql"|"api /graphql")
    resource=graphql
    for arg in "$@"; do
      case "$arg" in *mutation*|*Mutation*) direction=write ;; esac
    done
    ;;
  "api "*)
    resource=core
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
  "pr view"|"pr list"|"pr status"|"pr checks"|"pr diff"|"issue view"|"issue list"|"issue status"|"run view"|"run list"|"run watch"|"search "*) ;;
  "pr "*|"issue "*|"run rerun"|"run cancel"|"run delete"|"label create"|"label delete"|"label edit") direction=write ;;
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

if [ "$status" -ne 0 ] && [ -n "$agent_quota_dir" ] && [ -n "$error_file" ] && grep -Eiq 'rate.?limit|rate_limit' "$error_file"; then
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
        printf '%s\n' "$core_reset" > "$agent_quota_dir/core-hold" 2>/dev/null || true
        exhausted=1
        ;;
    esac
    case "$graphql_remaining:$graphql_reset" in
      0:[0-9]*)
        printf '%s\n' "$graphql_reset" > "$agent_quota_dir/graphql-hold" 2>/dev/null || true
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
  # rejection. GitHub does not report a reset for these, hence the fixed wait.
  if [ "$exhausted" -eq 0 ]; then
    secondary_until=$(( $(date -u +%s) + 60 ))

    case "$resource" in
      core|graphql) printf '%s\n' "$secondary_until" > "$agent_quota_dir/$resource-secondary-hold" 2>/dev/null || true ;;
      *)
        printf '%s\n' "$secondary_until" > "$agent_quota_dir/core-secondary-hold" 2>/dev/null || true
        printf '%s\n' "$secondary_until" > "$agent_quota_dir/graphql-secondary-hold" 2>/dev/null || true
        ;;
    esac

    printf '%s\n' 'aiur: GitHub secondary rate limit; backing off 60s before the next call' >&2
  fi
fi

if [ -n "$error_file" ]; then rm -f "$error_file" 2>/dev/null || true; fi
exit "$status"
