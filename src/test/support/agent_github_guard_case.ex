defmodule Aiur.AgentGitHubGuardCase do
  @moduledoc false
  # Installs the agent guards into a throwaway workspace beside a fake `gh`.

  use ExUnit.CaseTemplate

  alias Aiur.AgentGitHubGuard

  using do
    quote do
      @moduletag :tmp_dir

      import Aiur.AgentGitHubGuardCacheSupport
      import Aiur.AgentGitHubGuardTestSupport
      import ExUnit.CaptureLog

      alias Aiur.AgentGitHubGuard
      alias Aiur.GitHub.{AgentCache, Budget, ResourceStore}
    end
  end

  setup %{tmp_dir: root} do
    workspace = Path.join(root, "1670")
    state_path = Path.join(root, "state")
    fake_gh = Path.join(root, "real-bin/gh")
    fake_jq = Path.join(root, "real-bin/jq")
    failing_broker = Path.join(root, "failing-broker.py")
    wait_broker = Path.join(root, "wait-broker.py")
    calls = Path.join(root, "calls")
    File.mkdir_p!(workspace)

    File.mkdir_p!(Path.dirname(fake_gh))

    File.write!(
      fake_gh,
      """
      #!/bin/sh
      if [ "${1:-}" = api ] && { [ "${2:-}" = rate_limit ] || [ "${2:-}" = /rate_limit ]; }; then
        printf '%s' "${FAKE_RATE_LIMIT:-5000 0 5000 0}"
        exit 0
      fi
      if [ "${FAKE_GH_REJECT_INCLUDE:-0}" = 1 ]; then
        for fake_arg in "$@"; do
          if [ "$fake_arg" = --include ]; then printf '%s\n' 'unexpected include' >&2; exit 99; fi
        done
      fi
      # Emit a `GH_DEBUG=api`-shaped transcript to stderr, including HTTP
      # status lines, so high-level 304 reconciliation can be exercised. The
      # transcript must end with `* Request took` (the strip boundary), and
      # `FAKE_GH_DEBUG_ERROR` — if set — lands after it exactly where `gh`
      # prints real errors. `FAKE_GH_DEBUG_PRE` lands BEFORE the first request
      # marker, standing in for the `[git remote -v]` / `[git config ...]`
      # subprocess lines `gh` emits ahead of the request; `FAKE_GH_DEBUG_STATUSES`
      # (space-separated) emits several status lines to model a command that
      # makes more than one HTTP request under a single lease.
      if [ -n "${FAKE_GH_DEBUG_PRE:-}" ]; then
        printf '%s\n' "$FAKE_GH_DEBUG_PRE" >&2
      fi
      if [ -n "${FAKE_GH_DEBUG_STATUS:-}" ] || [ -n "${FAKE_GH_DEBUG_STATUSES:-}" ]; then
        printf '%s\n' "* Request at 2026-08-22 19:20:31 -0700 PDT m=+0.030400534" >&2
        printf '%s\n' "* Request to https://api.github.com/graphql" >&2
        printf '%s\n' "> POST /graphql HTTP/2" >&2
        printf '%s\n' "> Host: api.github.com" >&2
        printf '%s\n' "" >&2
        if [ -n "${FAKE_GH_DEBUG_STATUSES:-}" ]; then
          for fake_debug_status in $FAKE_GH_DEBUG_STATUSES; do
            printf '%s\n' "< HTTP/2.0 $fake_debug_status" >&2
          done
          unset fake_debug_status
        else
          printf '%s\n' "< HTTP/2.0 ${FAKE_GH_DEBUG_STATUS}" >&2
        fi
        printf '%s\n' "< X-RateLimit-Limit: 5000" >&2
        printf '%s\n' "< X-RateLimit-Remaining: 4999" >&2
        printf '%s\n' "" >&2
        printf '%s\n' '{"data":{"viewer":{"login":"fake"}}}' >&2
        printf '%s\n' "" >&2
        printf '%s\n' "* Request took 12.345ms" >&2
      fi
      if [ -n "${FAKE_GH_DEBUG_ERROR:-}" ]; then printf '%s\n' "$FAKE_GH_DEBUG_ERROR" >&2; fi
      if [ "${FAKE_GH_PASSTHROUGH_LOCAL:-0}" = 1 ]; then
        case " $* " in
          *" api http://127.0.0.1:"*)
            if [ -n "${FAKE_GH_FORMAT_ARGS:-}" ]; then printf '%s\n' "$*" >> "$FAKE_GH_FORMAT_ARGS"; fi
            if [ -n "${FAKE_GH_RENDER_ENV:-}" ]; then
              printf 'GH_TOKEN=%s\nGITHUB_TOKEN=%s\nNO_PROXY=%s\nno_proxy=%s\n' "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" "${NO_PROXY:-}" "${no_proxy:-}" > "$FAKE_GH_RENDER_ENV"
            fi
            if [ -n "${FAKE_GH_REPLAY_PROBE:-}" ]; then
              for fake_arg in "$@"; do
                case "$fake_arg" in
                  http://127.0.0.1:*) fake_probe_url=$fake_arg ;;
                esac
              done
              "$FAKE_GH_NATIVE" api "$fake_probe_url" --silent >/dev/null 2>&1
              printf '%s\n' "$?" > "$FAKE_GH_REPLAY_PROBE"
            fi
            if [ -n "${FAKE_GH_PROC_REPLAY_PROBE:-}" ]; then
              python3 - "$$" "$FAKE_GH_PROC_REPLAY_PROBE" <<'PY'
      import re
      import sys
      import urllib.error
      import urllib.request

      renderer_pid, result_path = sys.argv[1:]
      try:
          with open(f"/proc/{renderer_pid}/cmdline", "rb") as cmdline:
              match = re.search(rb"http://127[.]0[.]0[.]1:[0-9]+/[^\\0 ]+", cmdline.read())
      except FileNotFoundError:
          match = None

      if not sys.platform.startswith("linux"):
          result = "proc-unavailable"
      elif match is None:
          result = "url-hidden"
      else:
          try:
              urllib.request.urlopen(match.group().decode("ascii"), timeout=5).read()
              result = "replay-read"
          except (OSError, urllib.error.HTTPError):
              result = "access-denied"

      with open(result_path, "w", encoding="utf-8") as output:
          output.write(result + "\\n")
      PY
            fi
            exec "$FAKE_GH_NATIVE" "$@"
            ;;
        esac
      fi
      for fake_arg in "$@"; do
        case "$fake_arg" in -q|--jq|-t|--template|--jq=*|--template=*) fake_formatted=1; break ;; esac
      done
      if [ "${fake_formatted:-0}" = 1 ]; then
        if [ -n "${FAKE_GH_FORMAT_ARGS:-}" ]; then printf '%s\n' "$*" >> "$FAKE_GH_FORMAT_ARGS"; fi
        printf '%b' "${FAKE_GH_FORMAT_OUTPUT:-formatted\n}"
        exit 0
      elif [ "${FAKE_GH_PAGINATION:-0}" = 1 ]; then
        fake_endpoint=
        for fake_arg in "$@"; do
          if [ "$fake_arg" = "repos/owner/repo/issues" ] || [ "$fake_arg" = "/repos/owner/repo/issues?page=2" ]; then
            fake_endpoint=$fake_arg
            break
          fi
        done
        if [ "$fake_endpoint" = "repos/owner/repo/issues" ]; then
          if [ -n "${FAKE_GH_PAGINATION_HEADERS:-}" ]; then
            printf '%b' "$FAKE_GH_PAGINATION_HEADERS"
          else
            printf '%s\n' 'HTTP/2 200' 'Link: <https://api.github.com/repos/owner/repo/issues?page=2>; rel="next"' ''
          fi
        elif [ "$fake_endpoint" = "/repos/owner/repo/issues?page=2" ]; then
          if [ -n "${FAKE_GH_PAGINATION_SECOND_HEADERS:-}" ]; then
            printf '%b' "$FAKE_GH_PAGINATION_SECOND_HEADERS"
          else
            printf '%s\n' 'HTTP/2 200' ''
          fi
          fake_page_failure=${FAKE_GH_FAIL_ON_SECOND_PAGE:-0}
        fi
      elif [ "${FAKE_GH_GRAPHQL_PAGINATION:-0}" = 1 ]; then
        case " $* " in
          *' endCursor=after-two '*) printf '%s\n' 'HTTP/2 200' '' '{"data":{"viewer":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' ;;
          *' endCursor=after-one '*) printf '%s\n' 'HTTP/2 200' '' '{"data":{"viewer":{"repositories":{"pageInfo":{"hasNextPage":true,"endCursor":"after-two"}}}}}' ;;
          *) printf '%s\n' 'HTTP/2 200' '' '{"data":{"viewer":{"repositories":{"pageInfo":{"hasNextPage":true,"endCursor":"after-one"}}}}}' ;;
        esac
      elif [ "${FAKE_GH_INCLUDE_HEADERS:-0}" = 1 ]; then
        printf '%b' "${FAKE_GH_HEADERS:-}"
      fi
      if [ "${FAKE_GH_PAGINATION:-0}" = 1 ]; then
        printf '%s %s\n' "${1:-}" "$fake_endpoint" >> "$FAKE_GH_CALLS"
      else
        printf '%s %s\n' "${1:-}" "${2:-}" >> "$FAKE_GH_CALLS"
      fi
      if [ -n "${FAKE_GH_ARGS:-}" ]; then printf '%s\n' "$*" >> "$FAKE_GH_ARGS"; fi
      # #2501: the guard deletes its marked `--body-file` copy on exit, so the
      # bytes it actually sent can only be observed from inside the call.
      if [ -n "${FAKE_GH_BODY_SINK:-}" ]; then
        fake_body_prior=
        for fake_arg in "$@"; do
          case "$fake_arg" in
            --body-file=*) cat "${fake_arg#--body-file=}" > "$FAKE_GH_BODY_SINK" 2>/dev/null || true ;;
            *)
              case "$fake_body_prior" in
                --body-file|-F) cat "$fake_arg" > "$FAKE_GH_BODY_SINK" 2>/dev/null || true ;;
              esac
              ;;
          esac
          fake_body_prior=$fake_arg
        done
        unset fake_arg fake_body_prior
      fi
      if [ "${FAKE_GH_GRAPHQL_PAGINATION:-0}" = 1 ]; then exit 0; fi
      if [ -n "${FAKE_GH_PAGINATION_BODY+x}" ]; then printf '%s\n' "$FAKE_GH_PAGINATION_BODY"; exit 0; fi
      if [ "${FAKE_GH_PAGINATION_JSON:-0}" = 1 ]; then printf '%s\n' '[]'; exit 0; fi
      sleep "${FAKE_GH_SLEEP:-0}"
      # Real `gh` exits 1 and prints `gh: HTTP 304` on stderr for a 304; the
      # guard must detect the 304 from the response status line, answer from
      # the cache, and suppress that stderr. Opt-in so the pre-conditional
      # tests keep the old mock's exit-0 304 shape (#2307 conditional reads).
      if [ "${FAKE_GH_304_ERROR:-0}" = 1 ] && printf '%s' "${FAKE_GH_HEADERS:-}" | grep -Eq '^HTTP/[^[:space:]]+[[:space:]]+304'; then
        printf '%s\n' 'gh: HTTP 304' >&2
        exit 1
      fi
      if [ "${FAKE_GH_FAIL:-0}" = 1 ] || [ "${fake_page_failure:-0}" = 1 ]; then printf '%s\n' "${FAKE_GH_ERROR:-failed}" >&2; exit 1; fi
      if [ -n "${FAKE_GH_BODY:-}" ]; then printf '%b' "$FAKE_GH_BODY"; else printf 'ok\n'; fi
      """
    )

    File.chmod!(fake_gh, 0o755)
    File.write!(fake_jq, "#!/bin/sh\nprintf '%s\\n' 'unexpected system jq invocation' >&2\nexit 89\n")
    File.chmod!(fake_jq, 0o755)
    # A broker that aborts the way a real one does: a diagnostic on stderr and a
    # non-zero exit. The wrapper must carry that text into its refusal (#2499).
    File.write!(failing_broker, "import sys\nprint('simulated broker abort', file=sys.stderr)\nsys.exit(1)\n")
    File.chmod!(failing_broker, 0o755)
    File.write!(wait_broker, "import os\nprint(os.environ['FAKE_BROKER_RESPONSE'])\n")
    File.chmod!(wait_broker, 0o755)
    :ok = AgentGitHubGuard.install(workspace)

    {:ok,
     wrapper: Path.join(AgentGitHubGuard.bin_dir(workspace), "gh"),
     git_wrapper: Path.join(AgentGitHubGuard.bin_dir(workspace), "git"),
     workspace: workspace,
     state_path: state_path,
     fake_gh: fake_gh,
     fake_jq: fake_jq,
     failing_broker: failing_broker,
     wait_broker: wait_broker,
     calls: calls}
  end
end
