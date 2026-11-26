# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
# ---------------------------------------------------------------------------
# SHARED GITHUB STATE CACHE (#2073 U6)
#
# The broker rations permission but stores no answers; this section serves each
# answer once from a store every agent on the host shares. Three rules govern it:
#
#  1. REPLAY BYTES, NEVER RECONSTRUCT THEM. A hit returns the exact stdout the
#     real `gh` produced for an invocation whose output-affecting arguments
#     (`--json`, `--jq`, `--template`, tty) hash identically.
#
#  2. KEYED BY RESOURCE IDENTITY; THE SHAPE ONLY NAMES THE FILE.
#     `<owner>/<repo>/<kind>/<id>/<shape>` — one marker invalidates every shape.
#
#  3. ANY DOUBT FALLS THROUGH: an unrecognised command, unknown repository,
#     missing store, unparseable entry or non-zero exit leaves `$cache_body`
#     empty and the call proceeds as today. The cache may cost throughput when
#     it fails, never correctness.
#
# WHAT THIS IS NOT. Every agent runs as the SAME OS user and can write here,
# exactly as beside the shared budget database; real containment needs a
# separate UID per agent.
#
# CONDITIONAL REQUESTS (#2299): `gh api` reads revalidate with If-None-Match
# against a stored ETag and a served 304 is reconciled free; high-level reads
# are GraphQL with no validator and stay TTL-only — see apis/github.md.
# ---------------------------------------------------------------------------
# The store sits beside the budget broker's database, the one directory every
# agent on a host shares. It derives from the RAW env var rather than
# `$budget_root` (which defaults to `$HOME/.aiur/github-budget` when unset), so
# a harness that clears the budget root does not get a live cache in the
# operator's home directory.
cache_root=${AIUR_GITHUB_STATE_CACHE_ROOT:-}
if [ -z "$cache_root" ] && [ -n "${AIUR_GITHUB_BUDGET_ROOT:-}" ]; then
  cache_root=${AIUR_GITHUB_BUDGET_ROOT%/}/state-cache
fi
case "$cache_root" in
  /*) ;;
  *) cache_root= ;;
esac
# Whether THIS call reads and writes entries. Kept separate from the store's
# existence on purpose: the store is shared by every agent on the host, so a
# process opting out of reading must still retire what it changes. Gating
# invalidation on the same switch would let one agent's `--json`-free shell or
# one test harness leave every OTHER agent serving a stale answer for the rest
# of the window.
cache_reads=1
case "${AIUR_GITHUB_STATE_CACHE_ENABLED:-1}" in
  0|false|FALSE|no|NO|off|OFF) cache_reads=0 ;;
esac

# R10's strict-freshness bypass. A caller that must not be served stale — a
# merge decision, a CI verdict — sets this and pays for the round trip. Writes
# still invalidate, so the bypass never leaves a stale entry behind it.
cache_bypass=0
case "${AIUR_GITHUB_STATE_CACHE_BYPASS:-0}" in
  1|true|TRUE|yes|YES|on|ON) cache_bypass=1 ;;
esac

# Seconds, because that is the resolution `date` gives without a subprocess per
# comparison. A sub-second value rounds to zero, which still serves an entry
# written in the same second, so the setting is documented in whole seconds and
# a sub-second value is treated as "off" rather than pretending to a precision
# the entry stamps do not carry.
cache_ttl=${AIUR_GITHUB_STATE_CACHE_TTL_MS:-60000}
case "$cache_ttl" in ''|*[!0-9]*) cache_ttl=60000 ;; esac
if [ "$cache_ttl" -lt 1000 ]; then
  cache_reads=0
  cache_ttl=0
else
  cache_ttl=$((cache_ttl / 1000))
fi
cache_max_bytes=${AIUR_GITHUB_STATE_CACHE_MAX_BYTES:-1048576}
case "$cache_max_bytes" in ''|*[!0-9]*) cache_max_bytes=1048576 ;; esac

cache_owner=
cache_repo_name=
cache_kind=
cache_id=
cache_write_id=
cache_collection=0
cache_repo_dir=
cache_entry_dir=
cache_body=
cache_meta=
cache_stage=
cache_started_at=
cache_events_file=
cache_shape=

# `shasum`/`sha256sum` are how a shape becomes a filename. Without one there is
# no cache at all, which is the same safe no-op as an unset root.
cache_fingerprint() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | cut -d' ' -f1
  else
    return 1
  fi
}

cache_valid_digest() {
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

# Every argument is length-prefixed so no two argument vectors can serialise to
# the same bytes — `["a b"]` and `["a", "b"]` must not share an entry. The
# terminal and colour variables join them because `gh` renders differently on a
# TTY, and an entry written by a piped agent must never be replayed to an
# interactive Executor shell as if it were the same request.
#
# `cache_tty` is sampled at the top level because this function's own stdout is
# the fingerprint pipe, where `[ -t 1 ]` is false for every caller.
cache_tty=0
[ -t 1 ] && cache_tty=1

cache_material() {
  printf 'aiur-gh-cache/v2\n%s\n' "$cache_tty"
  # The credential the answer was fetched with. Everything else the broker keeps
  # — budgets, leases, cooldowns — is already keyed by this fingerprint, and a
  # response body is more identity-dependent than any of them: a private repo one
  # token cannot see, the `permissions` object, a collaborator list. Two
  # identities sharing one store must not share one answer.
  printf '%s\n' "${budget_key:-unkeyed}"
  printf '%s\n%s\n%s\n%s\n%s\n' "${NO_COLOR-}" "${CLICOLOR-}" "${CLICOLOR_FORCE-}" "${GH_FORCE_TTY-}" "${COLUMNS-}"
  printf '%s\n%s\n%s\n' "${GH_HOST-}" "${GH_REPO-}" "$#"
  for cache_arg in "$@"; do
    printf '%s\n%s\n' "${#cache_arg}" "$cache_arg"
  done
  unset cache_tty cache_arg
}

cache_valid_slug() {
  case "$1" in
    *[!A-Za-z0-9./_-]*|*..*|.*|*/) return 1 ;;
    */*/*) return 1 ;;
    ?*/?*) return 0 ;;
  esac
  return 1
}

cache_numeric() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 12 ]
}

# `https://github.com/OWNER/REPO/pull/2073` names its repository and its number
# outright, so it is a stronger identity than the inferred slug below and
# overrides it. Parsed with parameter expansion only — no subprocess.
cache_read_url_identity() {
  case "$1" in
    https://github.com/*/*/pull/*|https://github.com/*/*/pulls/*|https://github.com/*/*/issues/*) ;;
    *) return 1 ;;
  esac

  cache_url_rest=${1#https://github.com/}
  cache_url_owner=${cache_url_rest%%/*}
  cache_url_rest=${cache_url_rest#*/}
  cache_url_repo=${cache_url_rest%%/*}
  cache_url_rest=${cache_url_rest#*/}
  cache_url_type=${cache_url_rest%%/*}
  cache_url_number=${cache_url_rest#*/}
  cache_url_number=${cache_url_number%%/*}
  cache_url_number=${cache_url_number%%\?*}
  cache_url_number=${cache_url_number%%\#*}

  if cache_valid_slug "$cache_url_owner/$cache_url_repo" && cache_numeric "$cache_url_number"; then
    cache_owner=$cache_url_owner
    cache_repo_name=$cache_url_repo
    cache_id=$cache_url_number
    case "$cache_url_type" in
      issues) cache_kind=issue ;;
      *) cache_kind=pr ;;
    esac
    unset cache_url_rest cache_url_owner cache_url_repo cache_url_type cache_url_number
    return 0
  fi

  unset cache_url_rest cache_url_owner cache_url_repo cache_url_type cache_url_number
  return 1
}

if [ -n "$cache_root" ]; then
  # `--hostname` and `GH_HOST` move the request to another GitHub deployment
  # whose numbering is unrelated, so nothing is cached and — because entries of
  # THIS host must not be retired by a write against a different one — nothing
  # is invalidated either. A flag that names github.com explicitly is not a
  # different deployment, so it is compared rather than merely detected.
  cache_hostname_override=0
  cache_hostname_expected=0
  for cache_arg in "$@"; do
    if [ "$cache_hostname_expected" -eq 1 ]; then
      cache_hostname_expected=0
      case "$cache_arg" in
        github.com) ;;
        *) cache_hostname_override=1 ;;
      esac
      continue
    fi

    case "$cache_arg" in
      --hostname) cache_hostname_expected=1 ;;
      --hostname=github.com) ;;
      --hostname=*) cache_hostname_override=1 ;;
    esac
  done
  unset cache_hostname_expected
  case "${GH_HOST:-github.com}" in
    github.com) ;;
    *) cache_hostname_override=1 ;;
  esac
  [ "$cache_hostname_override" -eq 0 ] || cache_root=
  unset cache_hostname_override cache_arg
fi

if [ -n "$cache_root" ]; then
  # Repository identity, most explicit source first. The workspace anchor is
  # the subtle one: `AIUR_GITHUB_REPO` is the repo the daemon dispatched this
  # agent against, and `gh` resolves the repo from the working directory, so the
  # two only agree while the agent is inside its own workspace. An agent that
  # cloned something else and ran `gh pr view 5` there would have its answer
  # filed under the wrong repository — so that case resolves to no identity
  # and is not cached.
  cache_flag_repo=
  cache_prior=
  for cache_arg in "$@"; do
    case "$cache_prior" in
      -R|--repo) cache_flag_repo=$cache_arg ;;
    esac
    case "$cache_arg" in
      -R?*) cache_flag_repo=${cache_arg#-R} ;;
      --repo=*) cache_flag_repo=${cache_arg#--repo=} ;;
    esac
    cache_prior=$cache_arg
  done

  cache_slug=
  if [ -n "$cache_flag_repo" ]; then
    cache_slug=$cache_flag_repo
  elif [ -n "${GH_REPO:-}" ]; then
    cache_slug=$GH_REPO
  elif [ -n "${AIUR_GITHUB_REPO:-}" ] && [ -n "${AIUR_AGENT_WORKSPACE:-}" ]; then
    case "${PWD:-}" in
      "$AIUR_AGENT_WORKSPACE"|"$AIUR_AGENT_WORKSPACE"/*) cache_slug=$AIUR_GITHUB_REPO ;;
    esac
  fi

  if cache_valid_slug "$cache_slug"; then
    cache_owner=${cache_slug%%/*}
    cache_repo_name=${cache_slug#*/}
  fi

  unset cache_flag_repo cache_prior cache_arg cache_slug
fi

# The `--json` fields whose value is a verdict rather than a fact: CI state, and
# whether a pull request can be merged. `gh pr checks` is excluded for the same
# reason — and would have been unsafe in a second way: it exits 1 for failure
# and 8 for pending while only a zero-status response is ever stored, so the
# only verdict it could ever replay is "everything passed".
cache_volatile_fields() {
  case ",$1," in
    *,statusCheckRollup,*|*,mergeable,*|*,mergeStateStatus,*|*,mergeCommit,*|\
    *,reviewDecision,*|*,latestReviews,*|*,reviews,*|*,state,*|*,merged,*|*,mergedAt,*|\
    *,closed,*|*,closedAt,*|*,headRefOid,*|*,commits,*) return 0 ;;
  esac
  return 1
}

# REST equivalents of the verdict and merge-gating fields above: a caller
# spelling the same read as `gh api` must not acquire a stale answer merely by
# bypassing `gh pr view`. The pull-request resource itself is included because
# its default document carries `mergeable`, `mergeable_state`, `merged` and
# `state` — the exact fields `gh pr view --json ...` refuses — and nothing that
# changes them passes through this wrapper, so a `pulls/<n>/comments` read filed
# under that PR can never be retired by the write that would stale it.
#
# Deliberate divergence from `Aiur.GitHub.ReadCache.Policy`: the daemon refuses
# every `/actions` path wholesale; this wrapper keeps stable workflow metadata
# (`actions/workflows`) cacheable and refuses only run and job state — a
# workflow definition changes when its YAML is edited, a run's status is a
# verdict nothing retires.
cache_unsafe_rest_endpoint() {
  case "/${1#/}" in
    */check-runs|*/check-runs/*|*/check-suites|*/check-suites/*|\
    */status|*/status/*|*/statuses|*/statuses/*|\
    */pulls|*/pulls/*|*/merge|*/merge/*|*/requested_reviewers|*/requested_reviewers/*|\
    */reviews|*/reviews/*|*/actions/runs|*/actions/runs/*|\
    */actions/jobs|*/actions/jobs/*|*/actions/workflows/*/runs|\
    */actions/workflows/*/runs/*|*/actions/workflows/*/workflow_runs|\
    */actions/workflows/*/workflow_runs/*) return 0 ;;
    *) return 1 ;;
  esac
}

# The output shapes this guard serves. Everything absent from this list — a
# bare `gh pr view` with no number, `gh pr diff`, `gh api graphql`, every write
# — falls through to the real `gh` untouched.
#
# `--json` is required for the high-level commands on purpose: without it `gh`
# prints a human table with relative timestamps and terminal-width layout,
# which is neither stable across agents nor meaningful to replay.
if [ -n "$cache_root" ]; then
  cache_has_json=0
  cache_has_web=0
  cache_has_payload=0
  cache_volatile=0
  cache_options=1
  cache_expect_value=0
  cache_json_expected=0

  for cache_arg in "$@"; do
    [ "$cache_options" -eq 1 ] || break

    if [ "$cache_json_expected" -eq 1 ]; then
      cache_json_expected=0
      cache_expect_value=0
      cache_volatile_fields "$cache_arg" && cache_volatile=1
      continue
    fi

    if [ "$cache_expect_value" -eq 1 ]; then
      cache_expect_value=0
      continue
    fi

    case "$cache_arg" in
      --) cache_options=0 ;;
      --json|--jq|-q|--template|-t|--repo|-R|--hostname|--interval|-i|--limit|-L|--label|-l|\
      --assignee|-a|--author|-A|--search|-S|--state|-s|--base|-B|--head|-H|--milestone|-m|\
      --app|--mention|--cache|--header|--method|-X|--preview|-p)
        case "$cache_arg" in
          --json) cache_has_json=1; cache_json_expected=1 ;;
        esac
        cache_expect_value=1
        ;;
      --json=*)
        cache_has_json=1
        cache_volatile_fields "${cache_arg#--json=}" && cache_volatile=1
        ;;
      --web|-w) cache_has_web=1 ;;
      -F|-f|--field|--raw-field|--input) cache_has_payload=1; cache_expect_value=1 ;;
      -F*|-f*|--field=*|--raw-field=*|--input=*|*=@*|-) cache_has_payload=1 ;;
    esac
  done

  # R10. A merge decision and a CI verdict may not be served stale, ever, and
  # neither may be repaired after the fact: an agent that reads "all green" for a
  # commit CI has not seen, or "mergeable" for a branch that has moved, has
  # already acted on it. Nothing invalidates these — `git push` and a check run
  # completing never pass through this wrapper — so the freshness window is the
  # ONLY thing standing between the read and a wrong answer. These field names
  # are refused outright, never given a short window.
  [ "$cache_volatile" -eq 0 ] || cache_reads=0

  case "$command_key" in
    "pr view"|"issue view")
      if [ "$cache_has_json" -eq 1 ] && [ "$cache_has_web" -eq 0 ] && [ -n "$positional_three" ]; then
        if cache_numeric "$positional_three"; then
          cache_id=$positional_three
          case "$command_name" in
            pr) cache_kind=pr ;;
            *) cache_kind=issue ;;
          esac
        else
          cache_read_url_identity "$positional_three" || cache_id=
        fi
      fi
      ;;
    "pr list"|"issue list")
      if [ "$cache_has_json" -eq 1 ] && [ "$cache_has_web" -eq 0 ]; then
        cache_id=list
        cache_collection=1
        case "$command_name" in
          pr) cache_kind=pr ;;
          *) cache_kind=issue ;;
        esac
      fi
      ;;
    "api "*|"api")
      # REST GETs of a repository-scoped endpoint only. GraphQL is excluded:
      # its identity is an arbitrary document rather than a resource, so an
      # entry could not be invalidated by the resource writers above. Paginated
      # reads are excluded here and cached one page at a time, because the
      # pagination path re-enters this guard per page.
      if [ "$direction" = read ] && [ "$resource" = core ] && [ "$api_paginated" -eq 0 ] && [ "$cache_has_payload" -eq 0 ]; then
        cache_endpoint=$(api_command_endpoint "$@") || cache_endpoint=
        cache_endpoint=${cache_endpoint#/}
        # The query string is part of the SHAPE, which every argument is hashed
        # into anyway — it is not part of the resource's identity. Left on, a
        # `?per_page=1` moved the entry out of its resource's directory and into
        # a digest of the URL, where the resource's own writers cannot reach it.
        cache_endpoint=${cache_endpoint%%\?*}
        cache_endpoint=${cache_endpoint%%\#*}
        if cache_unsafe_rest_endpoint "$cache_endpoint"; then cache_reads=0; fi
        case "$cache_endpoint" in
          repos/*/*/*|repos/*/*)
            cache_api_rest=${cache_endpoint#repos/}
            cache_api_owner=${cache_api_rest%%/*}
            cache_api_rest=${cache_api_rest#*/}
            cache_api_repo=${cache_api_rest%%/*}
            if cache_valid_slug "$cache_api_owner/$cache_api_repo"; then
              cache_owner=$cache_api_owner
              cache_repo_name=$cache_api_repo

              # An endpoint that NAMES a resource is filed under that resource,
              # not under the endpoint. `repos/o/r/pulls/1670` and
              # `gh pr view 1670 --json body` are the same pull request, so a
              # writer retiring pull request 1670 must retire both — and it
              # cannot if one is filed under a URL digest the writer has never
              # seen. The endpoint still separates the two entries via the
              # hashed shape.
              cache_api_number=
              case "$cache_api_rest" in
                */issues/*|*/pulls/*)
                  cache_api_tail=${cache_api_rest#*/}
                  case "$cache_api_tail" in
                    issues/*) cache_api_kind=issue; cache_api_tail=${cache_api_tail#issues/} ;;
                    pulls/*) cache_api_kind=pr; cache_api_tail=${cache_api_tail#pulls/} ;;
                    *) cache_api_kind= ;;
                  esac
                  cache_api_number=${cache_api_tail%%/*}
                  if [ -n "$cache_api_kind" ] && cache_numeric "$cache_api_number"; then
                    cache_kind=$cache_api_kind
                    cache_id=$cache_api_number
                  fi
                  unset cache_api_tail cache_api_kind
                  ;;
              esac

              if [ -z "$cache_id" ]; then
                # An endpoint naming no single resource — a list, a search, a
                # repository-level read. Filed under the endpoint and treated as a
                # collection, so a write anywhere in the repository retires it.
                cache_kind=api
                cache_collection=1
                cache_id=$(printf '%s' "$cache_endpoint" | cache_fingerprint) || cache_id=
                cache_valid_digest "$cache_id" || cache_id=
              fi
              unset cache_api_number
            fi
            unset cache_api_rest cache_api_owner cache_api_repo
            ;;
        esac
        unset cache_endpoint
      fi
      ;;
  esac

  unset cache_has_json cache_has_web cache_has_payload cache_volatile cache_options cache_expect_value \
    cache_json_expected cache_arg
fi

