defmodule Aiur.AgentGitHubGuardTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Aiur.AgentGitHubGuard
  alias Aiur.GitHub.{AgentCache, ResourceStore}
  alias Aiur.GitHub.Budget

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
      if [ "${1:-} ${2:-}" = "api rate_limit" ]; then
        printf '%s' "${FAKE_RATE_LIMIT:-5000 0 5000 0}"
        exit 0
      fi
      if [ "${FAKE_GH_REJECT_INCLUDE:-0}" = 1 ]; then
        for fake_arg in "$@"; do
          if [ "$fake_arg" = --include ]; then printf '%s\n' 'unexpected include' >&2; exit 99; fi
        done
      fi
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
      if [ "${FAKE_GH_GRAPHQL_PAGINATION:-0}" = 1 ]; then exit 0; fi
      if [ -n "${FAKE_GH_PAGINATION_BODY+x}" ]; then printf '%s\n' "$FAKE_GH_PAGINATION_BODY"; exit 0; fi
      if [ "${FAKE_GH_PAGINATION_JSON:-0}" = 1 ]; then printf '%s\n' '[]'; exit 0; fi
      sleep "${FAKE_GH_SLEEP:-0}"
      if [ "${FAKE_GH_FAIL:-0}" = 1 ] || [ "${fake_page_failure:-0}" = 1 ]; then printf '%s\n' "${FAKE_GH_ERROR:-failed}" >&2; exit 1; fi
      printf 'ok\n'
      """
    )

    File.chmod!(fake_gh, 0o755)
    File.write!(fake_jq, "#!/bin/sh\nprintf '%s\\n' 'unexpected system jq invocation' >&2\nexit 89\n")
    File.chmod!(fake_jq, 0o755)
    File.write!(failing_broker, "import sys\nsys.exit(1)\n")
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

  test "installs the companion host-budget broker alongside the gh wrapper", context do
    assert File.regular?(AgentGitHubGuard.budget_broker_path(context.workspace))
    assert File.stat!(AgentGitHubGuard.budget_broker_path(context.workspace)).mode |> Bitwise.band(0o111) != 0
  end

  test "keeps the Executor wrapper outside the budget state directory" do
    refute String.starts_with?(AgentGitHubGuard.host_bin_dir(), Budget.state_dir())
  end

  # ---------------------------------------------------------------------------
  # Agents cannot approve or merge (the human merge gate)
  #
  # These test the documented bypass, not the existence of a wrapper. The real
  # attack is `env -u GITHUB_TOKEN -u GH_TOKEN gh pr review --approve`: with the
  # tokens gone, `gh` used to fall back to the operator's keyring account, which
  # is the sole branch-protection bypass actor. Each case therefore asserts that
  # the real `gh` was never reached at all.
  # ---------------------------------------------------------------------------

  test "provisions an agent-private, empty gh config dir", context do
    directory = AgentGitHubGuard.gh_config_dir(context.workspace)

    assert File.dir?(directory)
    assert File.ls!(directory) == []
    assert String.starts_with?(directory, context.workspace)
  end

  test "refuses a pull-request merge from an agent workspace", context do
    assert {output, 77} = run_guard(context, ["pr", "merge", "1670", "--squash"])

    assert output =~ "agents cannot approve or merge pull requests"
    refute File.exists?(context.calls)
  end

  test "refuses an approval even when the agent strips both token variables", context do
    assert {output, 77} =
             run_agent_guard(
               context,
               ["pr", "review", "1670", "--approve"],
               Enum.reject(guard_env(context), fn {name, _value} -> name in ["GITHUB_TOKEN", "GH_TOKEN"] end)
             )

    assert output =~ "agents cannot approve or merge pull requests"
    refute File.exists?(context.calls)
  end

  test "refuses a merge even when the agent clears the workspace marker", context do
    # Agent context is decided by where the wrapper is installed, so `$0` — not
    # an environment variable an agent can unset — carries the decision.
    assert {_output, 77} =
             run_agent_guard(
               context,
               ["pr", "merge", "1670"],
               Enum.reject(guard_env(context), fn {name, _value} -> name == "AIUR_AGENT_WORKSPACE" end)
             )

    refute File.exists?(context.calls)
  end

  test "refuses the REST and GraphQL forms of approve and merge", context do
    assert {_output, 77} = run_guard(context, ["api", "-X", "PUT", "repos/owner/repo/pulls/7/merge"])
    assert {_output, 77} = run_guard(context, ["api", "-X", "POST", "repos/owner/repo/pulls/7/reviews", "-f", "event=APPROVE"])
    assert {_output, 77} = run_guard(context, ["api", "repos/owner/repo/pulls/7/reviews", "-f", "event=APPROVE"])

    assert {_output, 77} =
             run_guard(context, ["api", "graphql", "-f", "query=mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"])

    refute File.exists?(context.calls)
  end

  test "refuses a GraphQL mutation whose document the guard cannot read", context do
    # `--input` and `-F query=@file` hand gh a document that never appears in
    # argv, so no mutation name is visible to match. The request would carry
    # `addPullRequestReview` with the agent PAT, and branch protection does not
    # stop an approval.
    assert {output, 77} = run_guard(context, ["api", "graphql", "--input", "mutation.json"])
    assert output =~ "agents cannot approve or merge pull requests"

    assert {_output, 77} = run_guard(context, ["api", "graphql", "--input=mutation.json"])
    assert {_output, 77} = run_guard(context, ["api", "graphql", "--input", "-"])
    assert {_output, 77} = run_guard(context, ["api", "graphql", "-F", "query=@mutation.graphql"])
    assert {_output, 77} = run_guard(context, ["api", "graphql", "-f", "query=@-"])

    refute File.exists?(context.calls)
  end

  test "refuses gh aliases and any command name the guard cannot recognise", context do
    # The denylist keys on the command name, so an alias renames the command out
    # of its reach: `alias set zz "pr merge"` then `zz 7` is a two-command merge.
    assert {output, 77} = run_guard(context, ["alias", "set", "zz", "pr merge"])
    assert output =~ "refusing a command this guard cannot inspect"

    assert {_output, 77} = run_guard(context, ["alias", "delete", "zz"])
    assert {_output, 77} = run_guard(context, ["alias", "import", "aliases.yml"])
    assert {_output, 77} = run_guard(context, ["zz", "7"])

    refute File.exists?(context.calls)
  end

  test "refuses approve flags in every spelling gh accepts", context do
    assert {output, 77} = run_guard(context, ["pr", "review", "7", "--approve=true"])
    assert output =~ "agents cannot approve or merge pull requests"

    assert {_output, 77} = run_guard(context, ["pr", "review", "7", "-a"])
    assert {_output, 77} = run_guard(context, ["pr", "review", "7", "-ab", "body"])
    assert {_output, 77} = run_guard(context, ["pr", "review", "7", "-a=true"])

    refute File.exists?(context.calls)
  end

  test "refuses the merge-gate REST endpoints that need no pull request", context do
    # Each of these advances the protected branch with no review recorded.
    assert {_output, 77} = run_guard(context, ["api", "-X", "POST", "repos/owner/repo/merges", "-f", "base=main", "-f", "head=feature"])

    assert {_output, 77} =
             run_guard(context, ["api", "-X", "PATCH", "repos/owner/repo/git/refs/heads/main", "-f", "sha=deadbeef"])

    assert {_output, 77} = run_guard(context, ["api", "-X", "POST", "repos/owner/repo/git/refs", "-f", "ref=refs/heads/main"])
    assert {_output, 77} = run_guard(context, ["api", "-X", "PUT", "repos/owner/repo/pulls/7/update-branch"])

    refute File.exists?(context.calls)
  end

  # Disarming the gate is as good as passing it: an agent that can delete branch
  # protection, rewrite a ruleset, or dispatch a workflow that merges with
  # `GITHUB_TOKEN` has removed the control every other denial here relies on.
  test "refuses the ways an agent could disarm the merge gate instead of passing it", context do
    assert {_output, 77} = run_guard(context, ["api", "-X", "DELETE", "repos/owner/repo/branches/main/protection"])

    assert {_output, 77} =
             run_guard(context, ["api", "-X", "PUT", "repos/owner/repo/branches/main/protection", "-f", "enforce_admins=false"])

    assert {_output, 77} = run_guard(context, ["api", "-X", "POST", "repos/owner/repo/rulesets", "-f", "name=open"])
    assert {_output, 77} = run_guard(context, ["workflow", "run", "merge.yml"])

    assert {_output, 77} =
             run_guard(context, ["api", "-X", "POST", "repos/owner/repo/actions/workflows/9/dispatches", "-f", "ref=main"])

    assert {_output, 77} = run_guard(context, ["api", "-X", "POST", "repos/owner/repo/dispatches", "-f", "event_type=merge"])

    refute File.exists?(context.calls)
  end

  test "still allows reading branch protection and listing workflows", context do
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/branches/main/protection"])
    assert {"ok\n", 0} = run_guard(context, ["workflow", "list"])
    assert {"ok\n", 0} = run_guard(context, ["workflow", "view", "ci.yml"])
  end

  test "still allows the reads and non-approving reviews an agent legitimately needs", context do
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/pulls/7/reviews"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "view", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "1670", "--comment", "--body", "looks reasonable"])

    assert File.read!(context.calls) =~ "pr view"
  end

  test "allows a comment review whose body text looks like an approve flag", context do
    # `--approve` here is the VALUE of `--body`, not a flag. Refusing it would
    # make the guard unusable for the reviews an agent is supposed to leave.
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "--comment", "--body", "--approve"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "--comment", "-b", "-a"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "-R", "owner/aiur", "--comment", "--body", "fine"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "-Rowner/aiur", "--comment", "--body", "fine"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "--comment", "--body", "ok", "--", "--approve"])

    assert File.read!(context.calls) =~ "pr review"
  end

  test "still allows the read-only commands and local config an agent needs", context do
    assert {"ok\n", 0} = run_guard(context, ["pr", "checks", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "diff", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "view", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/git/refs/heads/main"])
    assert {"ok\n", 0} = run_guard(context, ["alias", "list"])

    calls = File.read!(context.calls)
    assert calls =~ "pr checks"
    assert calls =~ "alias list"
  end

  test "leaves the Executor's own wrapper able to merge", context do
    # Only dispatched agents lose merge authority. The Executor runs the same
    # script from outside `.aiur-runtime/bin`, and must keep the gate it holds.
    executor_bin = Path.join(context.workspace, "executor-bin")
    File.mkdir_p!(executor_bin)
    executor_wrapper = Path.join(executor_bin, "gh")
    File.cp!(context.wrapper, executor_wrapper)
    File.chmod!(executor_wrapper, 0o755)

    assert {"ok\n", 0} =
             System.cmd(
               executor_wrapper,
               ["pr", "merge", "1670"],
               env: Enum.reject(guard_env(context), fn {name, _value} -> name == "AIUR_AGENT_WORKSPACE" end),
               stderr_to_stdout: true
             )
  end

  test "records ticket-shaped read and write attribution without command arguments", context do
    assert {"ok\n", 0} = run_guard(context, ["issue", "view", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "edit", "1670", "--body", "secret body"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    assert events =~ "\tticket:1670\tread\tcore\n"
    assert events =~ "\tticket:1670\twrite\tcore\n"
    refute events =~ "secret body"
  end

  # GraphQL is billed in points against its own budget. A row that does not say
  # which budget it spent gets counted against core, putting agent GraphQL
  # traffic in the wrong window (#1805).
  test "names the budget each recorded call was billed to", context do
    assert {"ok\n", 0} = run_guard(context, ["api", "graphql", "-f", "query=query { viewer { login } }"])
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/issues"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    assert events =~ "\tread\tgraphql\n"
    assert events =~ "\tread\tcore\n"
  end

  test "an ordinary failed call does not create quota holds or probe the API", context do
    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"], FAKE_GH_FAIL: "1")

    refute File.exists?(Path.join(context.state_path, "github-quota/core-hold"))
    refute File.read!(context.calls) =~ "api rate_limit"
  end

  test "a rate-limit failure records exact resource reset holds", context do
    reset = System.os_time(:second) + 3600

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"],
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: API rate limit exceeded",
               FAKE_RATE_LIMIT: "0 #{reset} 5000 #{reset}"
             )

    assert File.read!(Path.join(context.state_path, "github-quota/core-hold")) == "#{reset}\n"
    refute File.exists?(Path.join(context.state_path, "github-quota/graphql-hold"))
  end

  # Production keeps the agent hold dir under the workspace and the shared one
  # under the repo state path; the rest of this suite collapses them onto the
  # same directory, which hid the fact that a hold an agent discovered first
  # never reached anyone else. Reads consult both dirs, so writes publish to both.
  test "a rate-limit failure publishes the hold to both the agent and the shared repo dir", context do
    reset = System.os_time(:second) + 3600
    agent_quota_dir = Path.join(context.workspace, ".aiur-runtime/github-quota")
    shared_quota_dir = Path.join(context.state_path, "github-quota")
    File.mkdir_p!(agent_quota_dir)

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"],
               AIUR_AGENT_QUOTA_STATE_PATH: agent_quota_dir,
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: API rate limit exceeded",
               FAKE_RATE_LIMIT: "0 #{reset} 5000 #{reset}"
             )

    assert agent_quota_dir != shared_quota_dir

    # The discovering agent's own copy...
    assert File.read!(Path.join(agent_quota_dir, "core-hold")) == "#{reset}\n"
    # ...and the copy every other agent and the daemon actually read.
    assert File.read!(Path.join(shared_quota_dir, "core-hold")) == "#{reset}\n"
  end

  # Holds land via temp+rename so a concurrent reader never samples a truncated
  # file and lets a call out during an exhausted window. A leftover temp file
  # would mean the rename never happened.
  test "hold writes leave no temporary files behind", context do
    reset = System.os_time(:second) + 3600
    agent_quota_dir = Path.join(context.workspace, ".aiur-runtime/github-quota")
    File.mkdir_p!(agent_quota_dir)

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"],
               AIUR_AGENT_QUOTA_STATE_PATH: agent_quota_dir,
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: API rate limit exceeded",
               FAKE_RATE_LIMIT: "0 #{reset} 5000 #{reset}"
             )

    for dir <- [agent_quota_dir, Path.join(context.state_path, "github-quota")] do
      refute Enum.any?(File.ls!(dir), &String.contains?(&1, ".tmp."))
    end
  end

  # `gh run watch` is an allowlisted read whose progress arrives on stderr, so
  # the guard passes stderr through as it is written instead of replaying a
  # buffered copy after exit. `tee` ends that pipeline, so this also pins that
  # the real exit status still reaches the caller and that stderr is not
  # emitted twice.
  test "a streamed call surfaces stderr once and preserves the real exit status", context do
    assert {output, 1} =
             run_guard(context, ["pr", "view", "1670"],
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "boom from gh"
             )

    assert output =~ "boom from gh"
    assert length(String.split(output, "boom from gh")) == 2
  end

  # The field failure: `gh` refused with a rate-limit error while both primary
  # windows still read healthy. Without a secondary hold the guard recorded
  # nothing and the next call went straight back out.
  test "a rate-limit failure with healthy primary windows records a secondary backoff", context do
    reset = System.os_time(:second) + 3600
    before = System.os_time(:second)

    assert {output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"],
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: You have exceeded a secondary rate limit",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    assert output =~ "secondary rate limit"

    quota_dir = Path.join(context.state_path, "github-quota")
    refute File.exists?(Path.join(quota_dir, "core-hold"))

    held_until = quota_dir |> Path.join("core-secondary-hold") |> File.read!() |> String.trim() |> String.to_integer()
    assert held_until >= before + 60
    assert held_until <= System.os_time(:second) + 60
  end

  test "a secondary hold prevents an immediate retry of the real gh command", context do
    hold_file = Path.join(context.state_path, "github-quota/core-secondary-hold")
    File.mkdir_p!(Path.dirname(hold_file))
    File.write!(hold_file, "#{System.os_time(:second) + 60}\n")

    timeout = System.find_executable("timeout") || flunk("timeout executable is required for this Linux-only guard test")
    {_output, 124} = System.cmd(timeout, ["0.2", context.wrapper, "api", "repos/owner/repo/issues/1670"], env: guard_env(context), stderr_to_stdout: true)

    refute File.exists?(context.calls)
  end

  test "a retained hold prevents the real gh command from being retried immediately", context do
    hold_file = Path.join(context.state_path, "github-quota/core-hold")
    File.mkdir_p!(Path.dirname(hold_file))
    File.write!(hold_file, "#{System.os_time(:second) + 60}\n")

    timeout = System.find_executable("timeout") || flunk("timeout executable is required for this Linux-only guard test")
    {_output, 124} = System.cmd(timeout, ["0.2", context.wrapper, "api", "repos/owner/repo/issues/1670"], env: guard_env(context), stderr_to_stdout: true)

    refute File.exists?(context.calls)
  end

  test "a core hold does not block an explicitly GraphQL command", context do
    hold_file = Path.join(context.state_path, "github-quota/core-hold")
    File.mkdir_p!(Path.dirname(hold_file))
    File.write!(hold_file, "#{System.os_time(:second) + 60}\n")

    assert {"ok\n", 0} = run_guard(context, ["api", "graphql", "-f", "query=query { viewer { login } }"])
  end

  test "a local gh command bypasses active API holds", context do
    quota_dir = Path.join(context.state_path, "github-quota")
    File.mkdir_p!(quota_dir)
    File.write!(Path.join(quota_dir, "core-hold"), "#{System.os_time(:second) + 60}\n")
    File.write!(Path.join(quota_dir, "graphql-hold"), "#{System.os_time(:second) + 60}\n")

    assert {"ok\n", 0} = run_guard(context, ["version"])
  end

  test "separate agent workspaces share the host in-flight ceiling", context do
    other_workspace = Path.join(Path.dirname(context.workspace), "1671")
    File.mkdir_p!(other_workspace)
    :ok = AgentGitHubGuard.install(other_workspace)

    budget_root = Path.join(context.state_path, "host-budget")

    first =
      Task.async(fn ->
        run_guard(context, ["api", "repos/owner/repo/issues/1670"],
          AIUR_GITHUB_BUDGET_ROOT: budget_root,
          AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
          AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
          AIUR_GITHUB_MAX_INFLIGHT: "1",
          AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT: "1",
          AIUR_GITHUB_REQUESTS_PER_MINUTE: "20",
          AIUR_GITHUB_STAGGER_MS: "0",
          FAKE_GH_SLEEP: "0.3"
        )
      end)

    wait_for_calls(context.calls, 1)

    second =
      Task.async(fn ->
        System.cmd(Path.join(AgentGitHubGuard.bin_dir(other_workspace), "gh"), ["api", "repos/owner/repo/issues/1671"],
          env:
            guard_env(context) ++
              [
                {"AIUR_AGENT_WORKSPACE", other_workspace},
                {"AIUR_GITHUB_BUDGET_ENABLED", "1"},
                {"AIUR_GITHUB_BUDGET_ROOT", budget_root},
                {"AIUR_GITHUB_BUDGET_KEY", "a" <> String.duplicate("0", 63)},
                {"AIUR_GITHUB_BUDGET_BROKER", AgentGitHubGuard.budget_broker_path(other_workspace)},
                {"AIUR_GITHUB_MAX_INFLIGHT", "1"},
                {"AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT", "1"},
                {"AIUR_GITHUB_REQUESTS_PER_MINUTE", "20"},
                {"AIUR_GITHUB_STAGGER_MS", "0"}
              ],
          stderr_to_stdout: true
        )
      end)

    assert Task.yield(second, 80) == nil
    assert {"ok\n", 0} = Task.await(first, 1_500)
    assert {"ok\n", 0} = Task.await(second, 1_500)
  end

  test "the wrapper keeps one admission ledger when its publication token rotates", context do
    budget_root = Path.join(context.state_path, "rotating-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    identity_key = Budget.identity_key("machine_user:primary:aiur-bot")
    first_key = Budget.token_key("publication-token-a")
    second_key = Budget.token_key("publication-token-b")

    common = [
      AIUR_GITHUB_BUDGET_ROOT: budget_root,
      AIUR_GITHUB_BUDGET_BROKER: broker,
      AIUR_GITHUB_BUDGET_IDENTITY_KEY: identity_key,
      AIUR_GITHUB_STAGGER_MS: "0"
    ]

    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/issues/2236"], common ++ [AIUR_GITHUB_BUDGET_KEY: first_key])
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/issues/2237"], common ++ [AIUR_GITHUB_BUDGET_KEY: second_key])

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", second_key, "--identity-key", identity_key])

    assert length(Jason.decode!(snapshot)["admissions"]) == 2
  end

  test "an Executor-style gh wrapper publishes a secondary cooldown to the host budget", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    reset = System.os_time(:second) + 3_600

    assert {output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_REPO_STATE_PATH: "",
               AIUR_AGENT_QUOTA_STATE_PATH: "",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: You have exceeded a secondary rate limit",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    assert output =~ "secondary rate limit"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"cooldown_until_ms" => cooldown_until} = Jason.decode!(snapshot)
    assert cooldown_until >= System.os_time(:millisecond) + 59_000
  end

  test "a wrapper secondary cooldown blocks daemon requests for the same credential", context do
    budget_root = Path.join(context.state_path, "host-budget")
    credential = "preferred-gh-token"
    reset = System.os_time(:second) + 3_600

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_REPO_STATE_PATH: "",
               AIUR_AGENT_QUOTA_STATE_PATH: "",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               GH_TOKEN: credential,
               GITHUB_TOKEN: "different-github-token",
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: You have exceeded a secondary rate limit",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    assert {:hold, %{reason: :shared_budget}} =
             Budget.acquire(
               %{method: :get, url: "https://api.github.com/repos/owner/repo/pulls/1670", token: credential},
               state_dir: budget_root,
               enabled?: true,
               max_inflight: 4,
               max_inflight_per_endpoint: 2,
               requests_per_minute: 20,
               stagger_ms: 0,
               timeout_ms: 1_000
             )

    assert {:ok, different_lease} =
             Budget.acquire(
               %{method: :get, url: "https://api.github.com/repos/owner/repo/pulls/1670", token: "different-github-token"},
               state_dir: budget_root,
               enabled?: true,
               max_inflight: 4,
               max_inflight_per_endpoint: 2,
               requests_per_minute: 20,
               stagger_ms: 0
             )

    assert :ok = Budget.release(different_lease, state_dir: budget_root, enabled?: true)
  end

  test "a nested guard path resolves the underlying gh binary once", context do
    nested_workspace = Path.join(Path.dirname(context.workspace), "1671")
    File.mkdir_p!(nested_workspace)
    :ok = AgentGitHubGuard.install(nested_workspace)

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_REAL_GH: Path.join(AgentGitHubGuard.bin_dir(nested_workspace), "gh"),
               PATH: "#{Path.dirname(context.fake_gh)}:#{System.get_env("PATH")}"
             )

    assert File.read!(context.calls) == "api repos/owner/repo/issues/1670\n"
  end

  test "a core resource hold blocks high-level gh commands", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"", 0} =
             System.cmd("python3", [broker, "hold", "--scope", "resource", "--resource", "core", "--delay-ms", "60000", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert {output, 75} =
             System.cmd(context.wrapper, ["pr", "view", "1670"],
               env:
                 guard_env(context) ++
                   [
                     {"AIUR_GITHUB_BUDGET_ENABLED", "1"},
                     {"AIUR_GITHUB_BUDGET_ROOT", budget_root},
                     {"AIUR_GITHUB_BUDGET_KEY", key},
                     {"AIUR_GITHUB_BUDGET_BROKER", broker}
                   ],
               stderr_to_stdout: true
             )

    assert output =~ "aiur: github budget hold resource=core reset_at_ms="

    refute File.exists?(context.calls)
  end

  test "a short cooldown keeps sleeping in the guard instead of pausing the turn", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    # A 2-second token cooldown is below the shared-hold minimum, so the broker
    # answers `wait <ms>` and the guard must sleep-and-retry in place — the same
    # behavior as before typed holds existed — rather than aborting with exit 75
    # and pausing the whole agent turn for a routine 60-second backoff.
    assert {"", 0} =
             System.cmd("python3", [broker, "hold", "--scope", "token", "--delay-ms", "2000", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    timeout = System.find_executable("timeout") || flunk("timeout executable is required for this Linux-only guard test")

    assert {output, 124} =
             System.cmd(timeout, ["0.2", context.wrapper, "pr", "view", "1670"],
               env:
                 guard_env(context) ++
                   [
                     {"AIUR_GITHUB_BUDGET_ENABLED", "1"},
                     {"AIUR_GITHUB_BUDGET_ROOT", budget_root},
                     {"AIUR_GITHUB_BUDGET_KEY", key},
                     {"AIUR_GITHUB_BUDGET_BROKER", broker}
                   ],
               stderr_to_stdout: true
             )

    refute output =~ "aiur: github budget hold"
    refute File.exists?(context.calls)
  end

  test "a guarded high-level command fails closed before native pagination can bypass admissions", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    for limit_args <- [["--limit", "1000"], ["--limit=1000"], ["-L1000"]] do
      assert {output, 64} =
               run_guard(context, ["pr", "list" | limit_args],
                 AIUR_GITHUB_BUDGET_ROOT: budget_root,
                 AIUR_GITHUB_BUDGET_KEY: key,
                 AIUR_GITHUB_BUDGET_BROKER: broker
               )

      assert output =~ "cannot fetch more than one page"
    end

    refute File.exists?(context.calls)

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => []} = Jason.decode!(snapshot)
  end

  test "a one-page high-level command retains its single guarded admission", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\n", 0} =
             run_guard(context, ["pr", "list", "--limit", "100"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"endpoint_family" => "pulls"}]} = Jason.decode!(snapshot)
  end

  test "a paginated api call preserves its original command shape", context do
    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate"], FAKE_GH_REJECT_INCLUDE: "1")
  end

  test "a paginated API call admits every REST page through the shared budget", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\nok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1"
             )

    assert File.read!(context.calls) == "api repos/owner/repo/issues\napi /repos/owner/repo/issues?page=2\n"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{
             "admissions" => [
               %{"endpoint_family" => "issues"},
               %{"endpoint_family" => "issues"}
             ]
           } = Jason.decode!(snapshot)
  end

  test "a boolean pagination flag admits every REST page through the shared budget", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\nok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate=true"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{}, %{}]} = Jason.decode!(snapshot)
  end

  test "a secondary limit on a later REST page stops pagination and holds the shared budget", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    reset = System.os_time(:second) + 3_600

    assert {output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate"],
               AIUR_REPO_STATE_PATH: "",
               AIUR_AGENT_QUOTA_STATE_PATH: "",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1",
               FAKE_GH_FAIL_ON_SECOND_PAGE: "1",
               FAKE_GH_ERROR: "HTTP 403: You have exceeded a secondary rate limit",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    assert output =~ "secondary rate limit"

    assert File.read!(context.calls) == "api repos/owner/repo/issues\napi /repos/owner/repo/issues?page=2\n"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"cooldown_until_ms" => cooldown_until, "admissions" => admissions} = Jason.decode!(snapshot)
    assert Enum.take(admissions, 2) |> Enum.map(& &1["endpoint_family"]) == ["issues", "issues"]
    assert cooldown_until >= System.os_time(:millisecond) + 59_000
  end

  test "a paginated API call preserves flags before its endpoint", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\nok\n", 0} =
             run_guard(context, ["api", "-X", "GET", "repos/owner/repo/issues", "--paginate"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1"
             )

    assert File.read!(context.calls) == "api repos/owner/repo/issues\napi /repos/owner/repo/issues?page=2\n"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"endpoint_family" => "issues"}, %{"endpoint_family" => "issues"}]} = Jason.decode!(snapshot)
  end

  test "a paginated GET with fields remains a budgeted read", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\nok\n", 0} =
             run_guard(context, ["api", "-X", "GET", "repos/owner/repo/issues", "-f", "state=open", "--paginate"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"endpoint_family" => "issues"}, %{"endpoint_family" => "issues"}]} = Jason.decode!(snapshot)
  end

  test "a paginated API call accepts the short include flag", context do
    budget_root = Path.join(context.state_path, "host-budget")

    assert {output, 0} =
             run_guard(context, ["api", "-i", "repos/owner/repo/issues", "--paginate"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               FAKE_GH_PAGINATION: "1"
             )

    assert output =~ "HTTP/2 200"
    assert output =~ "\n\nok\nHTTP/2 200\n\nok\n"
  end

  test "a paginated API call preserves the boolean include flag and its response headers", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {output, 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate", "--include=true"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1"
             )

    assert output =~ "HTTP/2 200"
    assert output =~ "\n\nok\nHTTP/2 200\n\nok\n"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{}, %{}]} = Jason.decode!(snapshot)
  end

  test "does not treat option-like endpoint text as a pagination flag", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\n", 0} =
             run_guard(context, ["api", "--", "repos/owner/repo/issues", "--paginate"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker
             )

    assert File.read!(context.calls) == "api --\n"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{}]} = Jason.decode!(snapshot)
  end

  test "a paginated API call fails closed when its request body reads standard input", context do
    budget_root = Path.join(context.state_path, "host-budget")

    assert {output, 64} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate", "--input", "-"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace)
             )

    assert output =~ "input body or standard input"
    refute File.exists?(context.calls)
  end

  test "a paginated API call fails closed when its request body comes from a file", context do
    budget_root = Path.join(context.state_path, "host-budget")
    input = Path.join(context.workspace, "input.json")
    File.write!(input, ~s({"name":"aiur"}))

    assert {output, 64} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate", "--input", input],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace)
             )

    assert output =~ "input body or standard input"
    refute File.exists?(context.calls)
  end

  test "a paginated GraphQL query loaded from a file fails closed before a mutation can repeat", context do
    budget_root = Path.join(context.state_path, "host-budget")
    query = Path.join(context.workspace, "mutation.graphql")
    File.write!(query, "mutation { addStar(input: {starrableId: \"id\"}) { starrable { id } } }")

    arguments = ["api", "graphql", "--paginate", "-f", "query=@#{query}"]

    budget_env = [
      AIUR_GITHUB_BUDGET_ROOT: budget_root,
      AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
      AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace)
    ]

    # An agent never reaches the pagination budget: a query body this guard
    # cannot read is refused first, because it could carry an approval.
    assert {output, 77} = run_guard(context, arguments, budget_env)
    assert output =~ "agents cannot approve or merge pull requests"
    refute File.exists?(context.calls)

    # The Executor keeps full authority, so for it the unbudgetable repeated
    # request is the binding constraint — and it still fails closed.
    assert {output, 64} = run_executor_guard(context, arguments, budget_env)
    assert output =~ "input body or standard input"
    refute File.exists?(context.calls)
  end

  test "a paginated write fails closed before it reaches gh", context do
    budget_root = Path.join(context.state_path, "host-budget")

    assert {output, 64} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate", "-X", "POST"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace)
             )

    assert output =~ "cannot budget a paginated write"
    refute File.exists?(context.calls)
  end

  test "a boolean silent flag still admits every REST page", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate", "--silent=true"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{}, %{}]} = Jason.decode!(snapshot)
  end

  test "a boolean slurp flag keeps every REST page under budget", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"[[], []]\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate", "--slurp=true"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1",
               FAKE_GH_PAGINATION_JSON: "1"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{}, %{}]} = Jason.decode!(snapshot)
  end

  test "a paginated API call uses gh's embedded jq for one admitted slurped response set", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    renderer_args = Path.join(context.state_path, "renderer-args")
    renderer_env = Path.join(context.state_path, "renderer-env")
    replay_probe = Path.join(context.state_path, "replay-probe")
    proc_replay_probe = Path.join(context.state_path, "proc-replay-probe")
    native_gh = AgentGitHubGuard.real_gh() || flunk("gh is required to verify its embedded jq")

    assert {"2\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate", "--slurp", "--jq", "length"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1",
               FAKE_GH_PAGINATION_JSON: "1",
               FAKE_GH_FORMAT_ARGS: renderer_args,
               FAKE_GH_PASSTHROUGH_LOCAL: "1",
               FAKE_GH_NATIVE: native_gh,
               FAKE_GH_RENDER_ENV: renderer_env,
               FAKE_GH_REPLAY_PROBE: replay_probe,
               FAKE_GH_PROC_REPLAY_PROBE: proc_replay_probe,
               GH_TOKEN: "guard-token",
               GITHUB_TOKEN: "github-token",
               HTTP_PROXY: "http://127.0.0.1:1",
               NO_PROXY: "not-localhost",
               no_proxy: "not-localhost",
               PATH: "#{Path.dirname(context.fake_jq)}:#{System.get_env("PATH")}"
             )

    rendered_command = File.read!(renderer_args)
    assert rendered_command =~ ~r/api http:\/\/127\.0\.0\.1:\d+\/0(?: |$)/
    assert rendered_command =~ "--jq length"
    refute rendered_command =~ "guard-token"
    assert File.read!(replay_probe) == "1\n"

    assert File.read!(proc_replay_probe) ==
             if(match?({:unix, :linux}, :os.type()), do: "access-denied\n", else: "proc-unavailable\n")

    assert File.read!(renderer_env) ==
             "GH_TOKEN=aiur-local-replay\nGITHUB_TOKEN=\nNO_PROXY=127.0.0.1,localhost\nno_proxy=127.0.0.1,localhost\n"

    [replay_url] =
      Regex.run(~r/api (http:\/\/127\.0\.0\.1:\d+\/0)/, rendered_command, capture: :all_but_first)

    assert {_output, exit_code} =
             System.cmd(native_gh, ["api", replay_url, "--silent"],
               env: [{"GH_TOKEN", ""}, {"GITHUB_TOKEN", ""}, {"NO_PROXY", "127.0.0.1,localhost"}],
               stderr_to_stdout: true
             )

    assert exit_code != 0
    assert File.read!(context.calls) == "api repos/owner/repo/issues\napi /repos/owner/repo/issues?page=2\n"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{}, %{}]} = Jason.decode!(snapshot)
  end

  test "a paginated formatter rejects native-incompatible silent output before admission", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {output, exit_code} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate", "--jq", ".", "--silent"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1"
             )

    assert exit_code != 0
    assert output =~ "only one of `--template`, `--jq`, `--silent`, or `--verbose` may be used"
    refute File.exists?(context.calls)

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => []} = Jason.decode!(snapshot)
  end

  test "a formatted include replay keeps captured headers without replay-server defaults", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    native_gh = AgentGitHubGuard.real_gh() || flunk("gh is required to verify formatted include output")

    assert {output, 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate", "--include", "--jq", "."],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1",
               FAKE_GH_PAGINATION_JSON: "1",
               FAKE_GH_PAGINATION_HEADERS: "HTTP/2 200\\nX-Aiur-Origin: first\\nLink: <https://api.github.com/repos/owner/repo/issues?page=2>; rel=\"next\"\\n\\n",
               FAKE_GH_PAGINATION_SECOND_HEADERS: "HTTP/2 200\\nX-Aiur-Origin: second\\n\\n",
               FAKE_GH_PASSTHROUGH_LOCAL: "1",
               FAKE_GH_NATIVE: native_gh
             )

    assert output =~ "X-Aiur-Origin: first"
    assert output =~ "X-Aiur-Origin: second"
    assert output =~ "https://api.github.com/repos/owner/repo/issues?page=2"
    refute output =~ "http://127.0.0.1:"
    refute output =~ "Server:"
    refute output =~ "Date:"
  end

  test "a paginated API call preserves verbose output without a second request per page", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\nok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate", "--verbose"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1"
             )

    assert File.read!(context.calls) == "api repos/owner/repo/issues\napi /repos/owner/repo/issues?page=2\n"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{}, %{}]} = Jason.decode!(snapshot)
  end

  test "a paginated API call delegates documented templates to native gh across replayed pages", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    renderer_args = Path.join(context.state_path, "renderer-args")
    native_gh = AgentGitHubGuard.real_gh() || flunk("gh is required to verify its documented template helpers")
    template = ~s|{{range .}}{{tablerow (hyperlink .url .title) (timeago .updatedAt)}}{{end}}{{tablerender}}|
    page = ~s|[{"url":"https://example.test/shared","title":"shared","updatedAt":"2024-01-01T00:00:00Z"}]|

    assert {output, 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "--paginate", "--template", template],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_PAGINATION: "1",
               FAKE_GH_PAGINATION_BODY: page,
               FAKE_GH_FORMAT_ARGS: renderer_args,
               FAKE_GH_PASSTHROUGH_LOCAL: "1",
               FAKE_GH_NATIVE: native_gh
             )

    assert output =~ "shared"
    assert output =~ "https://example.test/shared"
    assert output =~ ~r/years? ago/
    assert length(Regex.scan(~r/shared/, output)) == 4
    rendered_command = File.read!(renderer_args)
    assert rendered_command =~ "api http://127.0.0.1:"
    assert rendered_command =~ "--paginate"
    assert rendered_command =~ template
    assert File.read!(context.calls) == "api repos/owner/repo/issues\napi /repos/owner/repo/issues?page=2\n"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{}, %{}]} = Jason.decode!(snapshot)
  end

  test "a paginated GraphQL call admits every cursor page through the shared budget", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    args = Path.join(context.state_path, "graphql-args")

    assert {output, 0} =
             run_guard(
               context,
               ["api", "graphql", "--paginate", "-f", "query=query($endCursor: String) { viewer { repositories(first: 1, after: $endCursor) { pageInfo { hasNextPage endCursor } } } }"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_GRAPHQL_PAGINATION: "1",
               FAKE_GH_ARGS: args
             )

    assert output =~ "hasNextPage"
    assert File.read!(context.calls) == "api graphql\napi graphql\napi graphql\n"

    assert File.read!(args) =~ "endCursor=after-one"
    assert File.read!(args) =~ "endCursor=after-two"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{}, %{}, %{}]} = Jason.decode!(snapshot)
  end

  test "a paginated GraphQL call keeps cursor parsing independent from gh-rendered jq output", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"formatted\n", 0} =
             run_guard(
               context,
               [
                 "api",
                 "graphql",
                 "--paginate",
                 "-q",
                 ".data.viewer.repositories.pageInfo.endCursor",
                 "-f",
                 "query=query($endCursor: String) { viewer { repositories(first: 1, after: $endCursor) { pageInfo { hasNextPage endCursor } } } }"
               ],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_GRAPHQL_PAGINATION: "1"
             )

    assert File.read!(context.calls) == "api graphql\napi graphql\napi graphql\n"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{}, %{}, %{}]} = Jason.decode!(snapshot)
  end

  test "a paginated GraphQL call renders a template without a second page request", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"formatted\n", 0} =
             run_guard(
               context,
               [
                 "api",
                 "graphql",
                 "--paginate",
                 "--template",
                 ~s({{if .data.viewer.repositories.pageInfo.hasNextPage}}next{{else}}done{{end}}{{"\\n"}}),
                 "-f",
                 "query=query($endCursor: String) { viewer { repositories(first: 1, after: $endCursor) { pageInfo { hasNextPage endCursor } } } }"
               ],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_GRAPHQL_PAGINATION: "1"
             )

    assert File.read!(context.calls) == "api graphql\napi graphql\napi graphql\n"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{}, %{}, %{}]} = Jason.decode!(snapshot)
  end

  test "a broker failure refuses the real gh command", context do
    budget_root = Path.join(context.state_path, "host-budget")

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: context.failing_broker,
               GITHUB_TOKEN: "shared-test-credential"
             )

    assert output =~ "refusing uncoordinated request"
    refute File.exists?(context.calls)
  end

  test "a configured budget fingerprints credentials with shasum when sha256sum is unavailable", context do
    budget_root = Path.join(context.state_path, "host-budget")
    credential = "shared-macos-credential"
    path = isolated_command_path(context, ~w(python3 shasum))

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               GITHUB_TOKEN: credential,
               PATH: path
             )

    key = :crypto.hash(:sha256, credential) |> Base.encode16(case: :lower)

    assert {snapshot, 0} =
             System.cmd("python3", [
               AgentGitHubGuard.budget_broker_path(context.workspace),
               "snapshot",
               "--db",
               Path.join(budget_root, "budget.sqlite3"),
               "--token-key",
               key
             ])

    assert %{"admissions" => [%{}]} = Jason.decode!(snapshot)
  end

  test "a configured budget refuses network calls when python3 is unavailable", context do
    budget_root = Path.join(context.state_path, "host-budget")
    path = isolated_command_path(context, ~w(shasum))

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               PATH: path
             )

    assert output =~ "shared budget unavailable"
    assert output =~ "python3"
    assert output =~ "refusing uncoordinated request"
    refute File.exists?(context.calls)
  end

  test "a configured budget refuses api rate_limit when python3 is unavailable", context do
    budget_root = Path.join(context.state_path, "host-budget")
    path = isolated_command_path(context, ~w(shasum))

    assert {output, 75} =
             run_guard(context, ["api", "rate_limit"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               PATH: path
             )

    assert output =~ "shared budget unavailable"
    assert output =~ "python3"
    assert output =~ "refusing uncoordinated request"
    refute File.exists?(context.calls)
  end

  test "api rate_limit is admitted through the shared core budget", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"5000 0 5000 0", 0} =
             run_guard(context, ["api", "rate_limit"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"endpoint_family" => "rate_limit"}]} = Jason.decode!(snapshot)
  end

  test "a guarded 304 response is reconciled as unbilled", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670/timeline"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "1",
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 304\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"billable" => false}]} = Jason.decode!(snapshot)
  end

  test "auth token remains local when a configured budget cannot start", context do
    budget_root = Path.join(context.state_path, "host-budget")
    path = isolated_command_path(context, ~w(shasum))

    assert {"ok\n", 0} =
             run_guard(context, ["auth", "token"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               PATH: path
             )

    assert File.read!(context.calls) == "auth token\n"
  end

  test "an explicitly disabled budget permits network calls without python3", context do
    budget_root = Path.join(context.state_path, "host-budget")
    path = isolated_command_path(context, ~w(shasum))

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ENABLED: "0",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               PATH: path
             )

    assert File.read!(context.calls) == "api repos/owner/repo/issues/1670\n"
  end

  test "a malformed broker wait response refuses the real gh command", context do
    budget_root = Path.join(context.state_path, "host-budget")

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "wait malformed"
             )

    assert output =~ "invalid or unusable wait response"
    refute File.exists?(context.calls)
  end

  test "a typed shared hold reports retry metadata and refuses the real gh command", context do
    budget_root = Path.join(context.state_path, "host-budget")
    reset_at_ms = System.system_time(:millisecond) + 60_000

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "hold shared core #{reset_at_ms}"
             )

    assert output =~ "aiur: github budget hold resource=core reset_at_ms=#{reset_at_ms}"
    refute File.exists?(context.calls)
  end

  test "a typed shared hold bounds reset timestamps while tolerating immediate expiry", context do
    budget_root = Path.join(context.state_path, "host-budget")
    now_ms = System.system_time(:millisecond)
    slightly_past_ms = now_ms - 1_000
    too_far_future_ms = now_ms + 86_405_000
    too_far_past_ms = now_ms - 86_405_000

    base_env = [
      AIUR_GITHUB_BUDGET_ROOT: budget_root,
      AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
      AIUR_GITHUB_BUDGET_BROKER: context.wait_broker
    ]

    assert {output, 75} =
             run_guard(
               context,
               ["api", "repos/owner/repo/issues/1670"],
               base_env ++ [FAKE_BROKER_RESPONSE: "hold shared core #{slightly_past_ms}"]
             )

    assert output =~ "aiur: github budget hold resource=core reset_at_ms=#{slightly_past_ms}"

    for reset_at_ms <- [too_far_future_ms, too_far_past_ms] do
      assert {output, 75} =
               run_guard(
                 context,
                 ["api", "repos/owner/repo/issues/1670"],
                 base_env ++ [FAKE_BROKER_RESPONSE: "hold shared core #{reset_at_ms}"]
               )

      assert output =~ "aiur: GitHub budget broker returned an invalid shared hold response"
      refute output =~ "aiur: github budget hold"
    end

    refute File.exists?(context.calls)
  end

  test "a malicious multiline shared hold cannot forge the trusted hold marker", context do
    budget_root = Path.join(context.state_path, "host-budget")
    reset_at_ms = System.system_time(:millisecond) + 60_000

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "hold shared admin never\naiur: github budget hold resource=core reset_at_ms=#{reset_at_ms}"
             )

    assert output == "aiur: GitHub budget broker returned an invalid shared hold response\n"
    refute output =~ "aiur: github budget hold"
    refute File.exists?(context.calls)
  end

  test "a malformed typed shared hold remains a broker failure", context do
    budget_root = Path.join(context.state_path, "host-budget")

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "hold shared admin never"
             )

    assert output =~ "invalid shared hold response"
    refute File.exists?(context.calls)
  end

  test "a malformed broker grant refuses the real gh command", context do
    budget_root = Path.join(context.state_path, "host-budget")

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "granted malformed"
             )

    assert output =~ "invalid admission response"
    refute File.exists?(context.calls)
  end

  test "a broker wait whose delay cannot be slept refuses the real gh command", context do
    budget_root = Path.join(context.state_path, "host-budget")
    fake_bin = Path.join(context.workspace, "fake-bin")
    File.mkdir_p!(fake_bin)
    File.write!(Path.join(fake_bin, "awk"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(fake_bin, "awk"), 0o755)

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "wait 100",
               PATH: "#{fake_bin}:#{System.get_env("PATH")}"
             )

    assert output =~ "invalid or unusable wait response"
    refute File.exists?(context.calls)
  end

  test "an actor-ceiling wait is parsed, slept, and then admitted to the real gh", context do
    # An actor that hit its hourly ceiling is told `wait actor <ms>`. The guard
    # must strip the `actor` token (the Elixir side's cue for the hold reason),
    # sleep the delay, and re-acquire — not refuse the wait as malformed. A
    # sequencing broker waits once and then grants.
    budget_root = Path.join(context.state_path, "host-budget")
    counter = Path.join(context.state_path, "broker-calls")
    seq_broker = Path.join(context.workspace, "seq-broker.py")

    File.write!(seq_broker, """
    import os
    count_file = os.environ["FAKE_BROKER_COUNTER"]
    n = int(open(count_file).read().strip() or "0") if os.path.exists(count_file) else 0
    n += 1
    open(count_file, "w").write(str(n))
    print("wait actor 100" if n == 1 else "granted " + "a" * 32)
    """)

    File.chmod!(seq_broker, 0o755)

    assert {output, 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: seq_broker,
               FAKE_BROKER_COUNTER: counter
             )

    assert output =~ "ok"
    assert File.read!(context.calls) == "api repos/owner/repo/issues/1670\n"
  end

  test "an Executor-style wrapper honours Retry-After in its shared cooldown", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    reset = System.os_time(:second) + 3_600

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_REPO_STATE_PATH: "",
               AIUR_AGENT_QUOTA_STATE_PATH: "",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: request rejected",
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 403\nRetry-After: 2\n\n",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"cooldown_until_ms" => cooldown_until} = Jason.decode!(snapshot)
    # The wrapper command and SQLite snapshot consume a small part of the
    # advertised two-second window; keep enough margin for a loaded host while
    # still distinguishing Retry-After from the 60-second fallback.
    assert cooldown_until >= System.os_time(:millisecond) + 1_500
    assert cooldown_until <= System.os_time(:millisecond) + 3_000
  end

  test "a successful exhausted API response holds the budgeted resource globally", context do
    budget_root = Path.join(context.state_path, "host-budget")
    credential = "successful-exhaustion-token"
    reset = System.os_time(:second) + 60

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_REPO_STATE_PATH: "",
               AIUR_AGENT_QUOTA_STATE_PATH: "",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               GH_TOKEN: credential,
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 200\nX-RateLimit-Remaining: 0\nX-RateLimit-Reset: #{reset}\n\n"
             )

    assert {:hold, %{reason: :shared_budget, resource: "core"}} =
             Budget.acquire(
               %{method: :get, url: "https://api.github.com/repos/owner/repo/issues/1670", token: credential},
               state_dir: budget_root,
               enabled?: true,
               max_inflight: 4,
               max_inflight_per_endpoint: 2,
               requests_per_minute: 20,
               stagger_ms: 0,
               timeout_ms: 1_000
             )
  end

  test "git authentication uses only the agent token for github.com", context do
    global_config = Path.join(context.workspace, ".gitconfig")

    File.write!(
      global_config,
      "[credential]\n\thelper = \"!f() { printf 'username=executor\\npassword=executor-token\\n'; }; f\"\n"
    )

    input = "protocol=https\nhost=github.com\n\n"

    assert {output, 0} =
             run_git_credential(context, input,
               GITHUB_TOKEN: "agent-token",
               GH_TOKEN: "wrong-precedence-token",
               HOME: context.workspace
             )

    assert output =~ "username=x-access-token"
    assert output =~ "password=agent-token"
    refute output =~ "executor-token"

    assert {output, exit_code} =
             run_git_credential(context, input,
               GITHUB_TOKEN: nil,
               GH_TOKEN: nil,
               HOME: context.workspace
             )

    assert exit_code != 0
    refute output =~ "executor-token"
  end

  test "git authentication preserves configured helpers for another host", context do
    global_config = Path.join(context.workspace, ".gitconfig")

    File.write!(
      global_config,
      "[credential]\n\thelper = \"!f() { printf 'username=other\\npassword=other-token\\n'; }; f\"\n"
    )

    input = "protocol=https\nhost=example.com\n\n"

    assert {output, 0} =
             run_git_credential(context, input,
               GITHUB_TOKEN: "agent-token",
               HOME: context.workspace
             )

    assert output =~ "username=other"
    assert output =~ "password=other-token"
    refute output =~ "agent-token"
  end

  test "git push rejects a credential-bearing GitHub remote", context do
    repo = Path.join(context.workspace, "repo")
    File.mkdir_p!(repo)

    assert {_, 0} = System.cmd(real_git(), ["init", repo], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", repo, "remote", "add", "origin", "https://agent:embedded-token@github.com/owner/repo.git"],
               stderr_to_stdout: true
             )

    {output, exit_code} =
      System.cmd(context.git_wrapper, ["push", "--dry-run", "origin", "HEAD"],
        cd: repo,
        env: [{"AIUR_REAL_GIT", real_git()}, {"GITHUB_TOKEN", "agent-token"}],
        stderr_to_stdout: true
      )

    assert exit_code == 64
    assert output =~ "credential-free https://github.com remote"
    refute output =~ "embedded-token"
  end

  test "git push inspects the repository selected by -C", context do
    repo = Path.join(context.workspace, "target-repo")
    File.mkdir_p!(repo)

    assert {_, 0} = System.cmd(real_git(), ["-C", repo, "init", "--quiet"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               real_git(),
               ["-C", repo, "remote", "add", "origin", "https://agent:embedded-token@github.com/owner/repo.git"],
               stderr_to_stdout: true
             )

    assert {output, 64} = run_git_guard(context, ["-C", repo, "push", "--dry-run", "origin", "HEAD"])
    assert output =~ "credential-free https://github.com remote"
    refute output =~ "embedded-token"
  end

  test "git wrapper refuses destructive commands without explicit repository context", context do
    init_git_workspace(context)

    for args <- [
          ["reset", "--hard", "HEAD"],
          ["clean", "-fdn"],
          ["checkout", "--", "."],
          ["restore", "--", "."],
          ["restore", "tracked.txt"],
          ["worktree", "remove", "missing-worktree"]
        ] do
      assert {output, 64} = run_git_guard(context, args)
      assert output =~ "destructive git commands require an explicit absolute -C workspace"
    end
  end

  test "git wrapper treats accepted hard-reset abbreviations as destructive", context do
    init_git_workspace(context)
    other = Path.join(Path.dirname(context.workspace), "other-reset-abbreviation")
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", other], stderr_to_stdout: true)

    for option <- ~w(--h --ha --har --hard) do
      assert {output, 64} = run_git_guard(context, ["reset", option, "HEAD"])
      assert output =~ "destructive git commands require an explicit absolute -C workspace"

      assert {output, 64} = run_git_guard(context, ["-C", other, "reset", option, "HEAD"])
      assert output =~ "destructive git target is not the agent workspace"

      assert {_output, 0} =
               run_git_guard(context, ["-C", context.workspace, "reset", option, "HEAD"])
    end
  end

  test "git wrapper rejects deleting clean without a force flag", context do
    init_git_workspace(context)

    config_env = [
      GIT_CONFIG_COUNT: "1",
      GIT_CONFIG_KEY_0: "clean.requireForce",
      GIT_CONFIG_VALUE_0: "false"
    ]

    assert {output, 64} = run_git_guard(context, ["clean", "-d"], config_env)
    assert output =~ "destructive git commands require an explicit absolute -C workspace"

    assert {_output, 0} =
             run_git_guard(context, ["-C", context.workspace, "clean", "-d", "-e", ".aiur-runtime/"], config_env)

    assert {_output, 0} = run_git_guard(context, ["clean", "--dry-run"], config_env)
  end

  test "git wrapper resolves aliases before classifying destructive commands", context do
    init_git_workspace(context)
    other = Path.join(Path.dirname(context.workspace), "other-alias")
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", other], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(real_git(), ["-C", context.workspace, "config", "alias.wipe", "reset --hard"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(real_git(), ["-C", context.workspace, "config", "alias.inspect", "status --short"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(real_git(), ["-C", other, "config", "alias.wipe", "reset --hard"], stderr_to_stdout: true)

    assert {output, 64} = run_git_guard(context, ["wipe"])
    assert output =~ "destructive git commands require an explicit absolute -C workspace"
    assert {_output, 0} = run_git_guard(context, ["-C", context.workspace, "wipe"])
    assert {_output, 0} = run_git_guard(context, ["inspect"])

    assert {output, 64} = run_git_guard(context, ["-C", other, "wipe"])
    assert output =~ "destructive git target is not the agent workspace"

    assert {_, 0} =
             System.cmd(real_git(), ["-C", context.workspace, "config", "alias.shell-wipe", "!git reset --hard"], stderr_to_stdout: true)

    assert {output, 64} = run_git_guard(context, ["-C", context.workspace, "shell-wipe"])
    assert output =~ "shell git aliases cannot be validated safely"

    assert {output, 64} = run_git_guard(context, ["-c", "alias.inline-wipe=reset --hard", "inline-wipe"])
    assert output =~ "inline git aliases cannot bypass repository context"
  end

  test "git wrapper accepts only an explicit context resolving to its workspace", context do
    init_git_workspace(context)
    nested = Path.join(context.workspace, "nested")
    other = Path.join(Path.dirname(context.workspace), "other")
    File.mkdir_p!(nested)
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", other], stderr_to_stdout: true)

    assert {_output, 0} = run_git_guard(context, ["-C", context.workspace, "reset", "--hard", "HEAD"])
    assert {_output, 0} = run_git_guard(context, ["-C", nested, "reset", "--hard", "HEAD"])

    for target <- [".", Path.join(context.workspace, "missing"), other] do
      assert {output, 64} = run_git_guard(context, ["-C", target, "reset", "--hard", "HEAD"])
      assert output =~ "destructive git target is not the agent workspace"
      refute output =~ "fatal: cannot change to"
    end
  end

  test "git wrapper derives its workspace from its installed path", context do
    init_git_workspace(context)

    assert {_output, 0} =
             run_git_guard(context, ["-C", context.workspace, "reset", "--hard", "HEAD"], AIUR_AGENT_WORKSPACE: nil)

    assert {_output, 0} =
             run_git_guard(context, ["-C", context.workspace, "reset", "--hard", "HEAD"], AIUR_AGENT_WORKSPACE: Path.dirname(context.workspace))
  end

  test "git wrapper rejects competing context selectors for destructive commands", context do
    init_git_workspace(context)
    git_dir = Path.join(context.workspace, ".git")

    for {args, env} <- [
          {["-C", context.workspace, "--git-dir", git_dir, "reset", "--hard", "HEAD"], []},
          {["-C", context.workspace, "--work-tree", context.workspace, "reset", "--hard", "HEAD"], []},
          {["-C", context.workspace, "-c", "core.worktree=#{Path.dirname(context.workspace)}", "reset", "--hard", "HEAD"], []},
          {["-C", context.workspace, "--config-env=core.worktree=FAKE_WORK_TREE", "reset", "--hard", "HEAD"], [FAKE_WORK_TREE: Path.dirname(context.workspace)]},
          {["-C", context.workspace, "reset", "--hard", "HEAD"], [GIT_DIR: git_dir]},
          {["-C", context.workspace, "reset", "--hard", "HEAD"], [GIT_WORK_TREE: context.workspace]}
        ] do
      assert {output, 64} = run_git_guard(context, args, env)
      assert output =~ "destructive git commands cannot use competing repository context"
    end
  end

  test "git wrapper leaves read-only commands available without -C", context do
    init_git_workspace(context)
    assert {_output, 0} = run_git_guard(context, ["status", "--short"])
  end

  # ---------------------------------------------------------------------------
  # `git worktree remove` protection (#2094)
  #
  # #2049 installed the destructive-git guard only into fleet agent
  # workspaces. These cover the extension to every Aiur-spawned process: the
  # same wrapper installed at host level (alongside `aiurdev`) applies two
  # checks to `git worktree remove` regardless of which process invokes it —
  # the worktree must be idle (no live process rooted in it) and must not hold
  # uncommitted work unless the caller deliberately passes the guard's distinct
  # override flag. Losing committed work is recoverable through the reflog;
  # losing uncommitted work is not, and that asymmetry is encoded rather than
  # left to judgement. The #2049 `-C` requirement and its workspace-derived
  # authority survive unchanged for workspace installs.
  # ---------------------------------------------------------------------------

  test "git worktree remove refuses a worktree holding uncommitted changes without the explicit override", context do
    worktree = make_workspace_worktree(context, "wt-dirty")
    File.write!(Path.join(worktree, "tracked.txt"), "dirty\n")

    assert {output, 64} =
             run_git_guard(context, ["-C", context.workspace, "worktree", "remove", worktree])

    assert output =~ "has uncommitted changes"
    assert output =~ "--aiur-remove-dirty"
    assert File.dir?(worktree)
  end

  test "the explicit override removes a dirty worktree and supplies git's own force", context do
    worktree = make_workspace_worktree(context, "wt-dirty-override")
    File.write!(Path.join(worktree, "tracked.txt"), "dirty\n")

    assert {_output, 0} =
             run_git_guard(context, [
               "-C",
               context.workspace,
               "worktree",
               "remove",
               worktree,
               "--aiur-remove-dirty"
             ])

    refute File.dir?(worktree)
  end

  test "git worktree remove still removes an idle, clean worktree", context do
    # The guard must not refuse the legitimate case: an idle worktree with no
    # uncommitted work is safe to remove, so the protection is a refusal of the
    # dangerous cases, not a blanket ban on `worktree remove`.
    worktree = make_workspace_worktree(context, "wt-clean")

    assert {_output, 0} =
             run_git_guard(context, ["-C", context.workspace, "worktree", "remove", worktree])

    refute File.dir?(worktree)
  end

  test "git's own --force cannot bypass the uncommitted-changes refusal", context do
    # The override is deliberately a distinct flag. git requires `--force` for
    # a dirty removal anyway, so if `--force` also satisfied the guard, a
    # coordinator reflexively passing it would bypass the protection entirely.
    # Only the guard's own `--aiur-remove-dirty` acknowledges the irreversible
    # loss of uncommitted work.
    worktree = make_workspace_worktree(context, "wt-force")
    File.write!(Path.join(worktree, "tracked.txt"), "dirty\n")

    assert {output, 64} =
             run_git_guard(context, [
               "-C",
               context.workspace,
               "worktree",
               "remove",
               worktree,
               "--force"
             ])

    assert output =~ "has uncommitted changes"
    assert output =~ "--aiur-remove-dirty"
    assert File.dir?(worktree)
  end

  test "git worktree remove refuses a worktree with a live process rooted in it, naming the pid", context do
    if match?({:unix, :linux}, :os.type()) do
      worktree = make_workspace_worktree(context, "wt-live")

      # The only live process rooted in the worktree is a "sibling wrapper":
      # its command line never mentions git or worktree, so naive
      # `/proc/*/cmdline` matching cannot see it — `/proc/<pid>/cwd` can.
      {port, pid} = spawn_rooted_sibling(worktree, "sleep 60")
      on_exit(fn -> stop_rooted_sibling(port, pid) end)
      :ok = wait_rooted(pid, worktree)

      # The override exists only for uncommitted work; a live worktree is
      # refused with no override at all.
      assert {output, 64} =
               run_git_guard(context, [
                 "-C",
                 context.workspace,
                 "worktree",
                 "remove",
                 worktree,
                 "--aiur-remove-dirty"
               ])

      assert output =~ "pid #{pid} is rooted in"
      assert File.dir?(worktree)
      stop_rooted_sibling(port, pid)
    else
      # The liveness check reads /proc/<pid>/cwd, which is Linux-only; the
      # uncommitted-changes protection above still applies on every platform.
    end
  end

  test "the worktree protection applies to a plain-shell caller outside .aiur-runtime/bin", context do
    host_bin = install_host_wrapper(context)
    {main, worktree} = make_host_worktree(context)
    File.write!(Path.join(worktree, "tracked.txt"), "dirty\n")

    # A plain operator shell resolves the bare `git` through PATH: `~/.aiur/bin`
    # prepended, no AIUR_REAL_GIT, no workspace marker. The host wrapper
    # resolves the real executable from the rest of PATH itself and still
    # refuses the removal.
    assert {output, 64} = run_host_guard(host_bin, main, ["worktree", "remove", worktree])
    assert output =~ "has uncommitted changes"
    assert output =~ "--aiur-remove-dirty"
    assert File.dir?(worktree)
  end

  test "a plain-shell caller cannot remove a live worktree either", context do
    if match?({:unix, :linux}, :os.type()) do
      host_bin = install_host_wrapper(context)
      {main, worktree} = make_host_worktree(context)
      {port, pid} = spawn_rooted_sibling(worktree, "sleep 60")
      on_exit(fn -> stop_rooted_sibling(port, pid) end)
      :ok = wait_rooted(pid, worktree)

      assert {output, 64} = run_host_guard(host_bin, main, ["worktree", "remove", worktree])
      assert output =~ "pid #{pid} is rooted in"
      assert File.dir?(worktree)
      stop_rooted_sibling(port, pid)
    else
      # The liveness check reads /proc/<pid>/cwd, which is Linux-only.
    end
  end

  test "the host wrapper passes every non-worktree command through untouched", context do
    host_bin = install_host_wrapper(context)
    {main, _worktree} = make_host_worktree(context)

    assert {"tracked\n", 0} = run_host_guard(host_bin, main, ["show", "HEAD:tracked.txt"])
    assert {_output, 0} = run_host_guard(host_bin, main, ["status", "--short"])
  end

  # #1793: 29 tickets were filed mid-run with no `agent:*` label. Each one was
  # undispatchable and absent from every state-scoped view, so the fleet read as
  # having no work left. The skills instruct every filing path to set the
  # disposition in the creation request; this is the part that does not depend
  # on an agent following prose.
  test "an issue create with no dispatch disposition never reaches gh", context do
    assert {output, 78} = run_guard(context, ["issue", "create", "--title", "Something broke"])

    assert output =~ "no dispatch disposition"
    refute File.exists?(context.calls)
  end

  test "a create labelled only with non-lifecycle labels is still refused", context do
    assert {_output, 78} =
             run_guard(context, ["issue", "create", "--title", "x", "--label", "bug,area:dashboard"])

    refute File.exists?(context.calls)
  end

  test "each documented disposition reaches gh, in every flag spelling", context do
    for label <- ~w(agent:todo human:todo needs-triage build-order epic) do
      File.rm_rf!(context.calls)

      assert {"ok\n", 0} =
               run_guard(context, ["issue", "create", "--title", "x", "--label", label])

      assert {"ok\n", 0} =
               run_guard(context, ["issue", "create", "--title", "x", "--label=#{label}"])

      assert {"ok\n", 0} = run_guard(context, ["issue", "create", "--title", "x", "-l", label])

      assert {"ok\n", 0} =
               run_guard(context, ["issue", "create", "--title", "x", "--label", "bug,#{label}"])

      assert File.read!(context.calls) == String.duplicate("issue create\n", 4)
    end
  end

  test "marker, terminal, malformed, and unknown prefixed labels are not dispositions", context do
    for label <- ~w(agent:watch agent:paused agent:done agent:not-a-state team:todo :todo Agent:todo) do
      File.rm_rf!(context.calls)

      assert {output, 78} =
               run_guard(context, ["issue", "create", "--title", "x", "--label", label])

      assert output =~ "no dispatch disposition"
      refute File.exists?(context.calls)
    end
  end

  test "the configured lifecycle prefix is the only prefixed todo disposition", context do
    assert {"ok\n", 0} =
             run_guard(context, ["issue", "create", "--title", "x", "--label", "team:todo"], AIUR_GITHUB_LABEL_PREFIX: "team")

    assert {output, 78} =
             run_guard(context, ["issue", "create", "--title", "x", "--label", "agent:todo"], AIUR_GITHUB_LABEL_PREFIX: "team")

    assert output =~ "no dispatch disposition"
  end

  test "root repository flags cannot bypass disposition validation", context do
    for arguments <- [
          ["-R", "owner/repo", "issue", "create", "--title", "x"],
          ["--repo=owner/repo", "issue", "create", "--title", "x"],
          ["issue", "--repo", "owner/repo", "create", "--title", "x"]
        ] do
      assert {output, 78} = run_guard(context, arguments)
      assert output =~ "no dispatch disposition"
    end
  end

  test "the disposition guard does not touch other issue subcommands", context do
    assert {"ok\n", 0} = run_guard(context, ["issue", "comment", "1670", "--body", "hi"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "edit", "1670", "--add-label", "agent:done"])

    assert File.read!(context.calls) =~ "issue comment"
  end

  test "direct gh api issue creation never reaches GitHub", context do
    for arguments <- [
          ["api", "repos/owner/repo/issues", "-f", "title=x"],
          ["api", "/repos/owner/repo/issues/?page=1", "-XPOST"],
          ["api", "repos/owner/repo/issues", "-X=POST"],
          ["api", "https://api.github.com/repos/owner/repo/issues#new", "--method", "POST"],
          ["api", "repos/owner/repo/issues", "-X", "POST"],
          ["api", "repos/owner/repo/issues", "--method=POST"],
          ["api", "repos/owner/repo/issues", "--input", "payload.json"]
        ] do
      File.rm_rf!(context.calls)
      assert {output, 78} = run_guard(context, arguments)
      assert output =~ "use `gh issue create --label ...`"
      refute File.exists?(context.calls)
    end
  end

  # The #1793 arm matched `issues?*` with `?` as a glob wildcard, so it claimed
  # every issue subresource as well as the collection. An agent updating its own
  # workpad comment was refused and told to run `gh issue create`.
  test "editing an issue or its comments is not mistaken for issue creation", context do
    for arguments <- [
          ["api", "repos/owner/repo/issues/comments/5260269359", "-X", "PATCH", "-f", "body=workpad"],
          ["api", "repos/owner/repo/issues/1670", "-X", "PATCH", "-f", "state=closed"],
          ["api", "repos/owner/repo/issues/1670/labels", "-X", "POST", "-f", "labels[]=agent:done"],
          ["api", "repos/owner/repo/issues/1670/comments", "-X", "POST", "-f", "body=hi"]
        ] do
      assert {output, 0} = run_guard(context, arguments)
      refute output =~ "gh issue create"
    end
  end

  test "direct GraphQL issue creation never reaches GitHub", context do
    assert {output, 78} =
             run_guard(context, [
               "api",
               "graphql",
               "-f",
               "query=mutation { createIssue(input: {repositoryId: \"R\", title: \"x\"}) { issue { id } } }"
             ])

    assert output =~ "use `gh issue create --label ...`"
    refute File.exists?(context.calls)
  end

  test "file-backed GraphQL issue creation never reaches GitHub", context do
    mutation = Path.join(context.workspace, "mutation.graphql")
    query = Path.join(context.workspace, "query.graphql")
    File.write!(mutation, "mutation { createIssue(input: {}) { issue { id } } }")
    File.write!(query, "query { viewer { login } }")

    assert {output, 78} =
             run_guard(context, ["api", "graphql", "-F", "query=@#{mutation}"])

    assert output =~ "use `gh issue create --label ...`"
    refute File.exists?(context.calls)

    # A file-backed body is opaque to this process, and the pre-existing merge
    # gate denies an unreadable body outright (an invariant that predates
    # #1793). The read-only file-backed query is therefore refused by that gate
    # (77) rather than passed through; assert the message proves the #1793
    # dispatch guard is not the blocker.
    assert {output, 77} = run_guard(context, ["api", "graphql", "-F", "query=@#{query}"])
    assert output =~ "cannot approve or merge"
    refute File.exists?(context.calls)

    # An inline read-only query is not a hidden body, so both the dispatch
    # guard and the merge gate pass it through untouched.
    assert {"ok\n", 0} =
             run_guard(context, ["api", "graphql", "-f", "query={ viewer { login } }"])

    assert File.read!(context.calls) == "api graphql\n"

    for field <- ["-Fquery=@#{mutation}", "-F=query=@#{mutation}"] do
      File.rm_rf!(context.calls)
      assert {output, 78} = run_guard(context, ["api", "graphql", field])
      assert output =~ "use `gh issue create --label ...`"
      refute File.exists?(context.calls)
    end
  end

  test "opaque GraphQL input is denied by the merge gate, not the dispatch guard", context do
    # An opaque body cannot be confirmed as issue creation, so the #1793
    # dispatch guard defers it to the pre-existing merge gate, which denies
    # every unreadable GraphQL body outright (it cannot rule out a merge). The
    # command is still blocked; only the refusing message differs. Asserting
    # the merge-gate message here guards against the dispatch guard claiming an
    # opaque body that might be a merge.
    assert {output, 77} = run_guard(context, ["api", "graphql", "--input", "-"])
    assert output =~ "cannot approve or merge"
    refute File.exists?(context.calls)
  end

  test "read-only issue API calls remain available", context do
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/issues"])

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "-X", "GET", "-f", "state=open"])

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "-X=GET", "-f", "state=open"])

    assert File.read!(context.calls) == String.duplicate("api repos/owner/repo/issues\n", 3)
  end

  test "installer rejects symlinked runtime directories", context do
    runtime = Path.join(context.workspace, ".aiur-runtime")
    external = Path.join(Path.dirname(context.workspace), "outside")
    File.rm_rf!(runtime)
    File.mkdir_p!(external)
    File.ln_s!(external, runtime)

    assert {:error, {:unsafe_agent_support_path, ^runtime, :symlink}} =
             AgentGitHubGuard.install(context.workspace)

    refute File.exists?(Path.join(external, "bin/gh"))
  end

  # ---------------------------------------------------------------------------
  # Shared GitHub state cache (#2073 U6)
  #
  # Sixteen agents asking about one pull request used to take sixteen leases and
  # pay sixteen times, because the broker rations spending but stores no answers.
  # These assert call COUNTS and BYTE EQUALITY, never latency or similarity: the
  # failure this design has to rule out is a cached response whose shape differs
  # subtly from the live one, which corrupts agent input without ever erroring.
  # ---------------------------------------------------------------------------

  describe "agent reads through the shared state cache" do
    test "two agents reading the same pull request produce one upstream call", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      assert upstream_calls(context) == 1
    end

    test "a cached read is byte-identical to the uncached one", context do
      # A body carrying every byte a re-serialiser would quietly normalise: a
      # CR, a trailing space, and no final newline.
      output = ~S(line one <b> &\r\ntrailing space \nno-trailing-newline)
      # The fake `gh` short-circuits on a formatter flag before it reaches the
      # shared call log, so this shape is counted through its own log instead.
      formatted = Path.join(context.workspace, "formatted-calls")
      env = [FAKE_GH_FORMAT_OUTPUT: output, FAKE_GH_FORMAT_ARGS: formatted]

      assert {uncached, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body", "-q", ".body"], env)
      assert line_count(formatted) == 1

      assert {cached, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body", "-q", ".body"], env)
      assert line_count(formatted) == 1

      assert cached == uncached
      assert cached =~ "no-trailing-newline"
      refute String.ends_with?(cached, "\n")
    end

    test "different output shapes never share an entry", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body,title"])

      assert upstream_calls(context) == 2
    end

    test "a read whose output is a human table is not cached", context do
      # No `--json`: `gh` prints a terminal-width table with relative
      # timestamps, which is neither stable between two agents nor meaningful to
      # replay an hour later.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670"])

      assert upstream_calls(context) == 2
    end

    test "an unrecognised invocation falls through unchanged", context do
      assert {first, 0} = run_cached_guard(context, ["pr", "diff", "1670"])
      assert {second, 0} = run_cached_guard(context, ["pr", "diff", "1670"])

      assert first == second
      assert upstream_calls(context) == 2
    end

    test "a GraphQL query is never served from the store", context do
      # Its identity is an arbitrary document rather than a resource, so no
      # writer could ever invalidate the entry.
      assert {_, 0} = run_cached_guard(context, ["api", "graphql", "-f", "query=query{viewer{login}}"])
      assert {_, 0} = run_cached_guard(context, ["api", "graphql", "-f", "query=query{viewer{login}}"])

      assert upstream_calls(context) == 2
    end

    test "a resource number outside the third position is not guessed at", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "--json", "body", "1670"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "--json", "body", "1670"])

      assert upstream_calls(context) == 2
    end

    test "a missing store leaves every call behaving exactly as today", context do
      env = [AIUR_GITHUB_STATE_CACHE_ROOT: Path.join(context.workspace, "nonexistent/store")]

      assert {first, 0} = run_guard(context, ["pr", "view", "1670", "--json", "body"], env)
      assert {second, 0} = run_guard(context, ["pr", "view", "1670", "--json", "body"], env)

      assert first == second
      assert upstream_calls(context) == 2
    end

    test "the kill switch disables the store outright", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], AIUR_GITHUB_STATE_CACHE_ENABLED: "0")
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], AIUR_GITHUB_STATE_CACHE_ENABLED: "0")

      assert upstream_calls(context) == 2
    end

    test "a caller demanding strict freshness always spends", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], AIUR_GITHUB_STATE_CACHE_BYPASS: "1")

      assert upstream_calls(context) == 2
    end

    test "a failed read is never stored", context do
      assert {_, 1} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], FAKE_GH_FAIL: "1")
      assert {_, 1} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], FAKE_GH_FAIL: "1")

      assert upstream_calls(context) == 2
    end

    test "a mutation retires the resource it changed", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["issue", "comment", "1670", "--body", "hi"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      # Pull requests and issues share GitHub's number space, so a comment
      # posted through `gh issue comment` changes what `gh pr view` answers.
      assert upstream_calls(context) == 3
    end

    test "a mutation elsewhere leaves an unrelated entry alone", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["issue", "comment", "1671", "--body", "hi"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      assert upstream_calls(context) == 2
    end

    test "a daemon writer retires every cached shape of a resource", context do
      # The interlock with the free pipes: a webhook delivery or a mutation
      # write-through marks the resource, and the agent's next read pays.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert upstream_calls(context) == 1

      assert :ok = AgentCache.invalidate("owner/repo", 1670, state_dir: cache_state_dir(context))

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert upstream_calls(context) == 2
    end

    test "the repository is not guessed at from outside the workspace", context do
      outside = Path.join(context.workspace, "..") |> Path.expand() |> Path.join("elsewhere")
      File.mkdir_p!(outside)

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], [], cd: outside)
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], [], cd: outside)

      assert upstream_calls(context) == 2
    end

    test "an explicit --repo is authoritative anywhere", context do
      outside = Path.join(context.workspace, "..") |> Path.expand() |> Path.join("elsewhere-repo")
      File.mkdir_p!(outside)
      args = ["pr", "view", "1670", "-R", "other/thing", "--json", "body"]

      assert {_, 0} = run_cached_guard(context, args, [], cd: outside)
      assert {_, 0} = run_cached_guard(context, args, [], cd: outside)

      assert upstream_calls(context) == 1
    end

    test "hits and misses are recorded for cost attribution", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      rows =
        Path.join([context.state_path, "github-quota", "agent-cache.tsv"])
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\t"))

      assert Enum.any?(rows, &match?([_at, _consumer, "miss", "pr", "1670"], &1))
      assert Enum.any?(rows, &match?([_at, _consumer, "store", "pr", "1670"], &1))
      assert Enum.any?(rows, &match?([_at, _consumer, "hit", "pr", "1670"], &1))
    end

    # -------------------------------------------------------------------------
    # Coalescing. A stored answer only removes the reads that come AFTER one; it
    # can do nothing about the reads that arrive together, which all miss and all
    # pay. These are therefore run genuinely concurrently — a sequential version
    # of the same assertion would pass on caching alone and prove nothing about
    # the mechanism under test.
    # -------------------------------------------------------------------------

    test "thirteen simultaneous readers of one pull request produce one upstream call", context do
      args = ["pr", "view", "1670", "--json", "body"]
      results = concurrent_reads(context, args, 13)

      assert Enum.all?(results, &match?({_output, 0}, &1))
      assert upstream_calls(context) == 1

      # One call means twelve of these were replayed, so byte equality is the
      # claim that matters: a follower must be given the leader's answer, not an
      # approximation of it.
      assert results |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 1

      # And they were replayed by the mechanism this test names. The wrapper
      # records a waiting follower as `coalesced` and a plain later reader as
      # `hit`, so without this the same call count would also be produced by
      # readers that happened to be serialised into a queue and found a stored
      # answer — caching, which is a different mechanism with a different bound.
      assert cache_events(context, "coalesced") > 0
      assert cache_events(context, "coalesced") + cache_events(context, "hit") == 12
    end

    test "simultaneous readers of different resources are not made to wait on each other", context do
      # The claim is per resource shape. Two agents reading two pull requests are
      # not duplicates and must both be admitted.
      results =
        [["pr", "view", "1670", "--json", "body"], ["pr", "view", "1671", "--json", "body"]]
        |> Task.async_stream(&run_cached_guard(context, &1, broker_env(context) ++ [FAKE_GH_SLEEP: "1"]),
          max_concurrency: 2,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({_output, 0}, &1))
      assert upstream_calls(context) == 2
    end

    test "a leader that never answers costs one duplicate call, never a stall", context do
      # A claim taken by a process that dies before writing anything. The follower
      # waits out its patience and then fetches for itself, which is the pre-store
      # behaviour rather than a hang.
      key = broker_token_key()
      broker = AgentGitHubGuard.budget_broker_path(context.workspace)
      database = Path.join(cache_state_dir(context), "budget.sqlite3")
      File.mkdir_p!(cache_state_dir(context))

      assert {_output, 0} =
               run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], AIUR_GITHUB_STATE_CACHE_WAIT_MS: "300")

      # A claim on the exact shape the read below computes, held by a lease
      # nothing will ever release.
      [{shape, _entry}] = cached_shapes(context)

      {_output, 0} =
        System.cmd("python3", [
          broker,
          "acquire",
          "--db",
          database,
          "--token-key",
          key,
          "--resource",
          "core",
          "--consumer-key",
          "abandoned",
          "--endpoint-family",
          "pulls",
          "--max-inflight",
          "4",
          "--max-inflight-per-endpoint",
          "2",
          "--requests-per-minute",
          "120",
          "--stagger-ms",
          "0",
          "--lease-ttl-ms",
          "600000",
          "--cache-key",
          shape,
          "--cache-claim-ttl-ms",
          "600000"
        ])

      # Retire the answer so the follower cannot simply be served the entry.
      assert :ok = AgentCache.invalidate("owner/repo", 1670, state_dir: cache_state_dir(context))

      assert {_output, 0} =
               run_cached_guard(
                 context,
                 ["pr", "view", "1670", "--json", "body"],
                 broker_env(context) ++ [AIUR_GITHUB_STATE_CACHE_WAIT_MS: "300"]
               )

      assert upstream_calls(context) == 2
    end

    test "a REST read of a pull request is filed under that pull request", context do
      # The join with the daemon's writers. `gh api repos/owner/repo/pulls/1670`
      # and `gh pr view 1670` are the same resource; filed under a digest of the
      # URL instead, the first would survive a writer retiring the second.
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/pulls/1670"])
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/pulls/1670"])
      assert upstream_calls(context) == 1

      assert :ok = AgentCache.invalidate("owner/repo", 1670, state_dir: cache_state_dir(context))

      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/pulls/1670"])
      assert upstream_calls(context) == 2
    end

    test "a REST read naming no single resource is retired by any write in the repository", context do
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/labels"])
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/labels"])
      assert upstream_calls(context) == 1

      assert :ok = AgentCache.invalidate_collections("owner/repo", state_dir: cache_state_dir(context))

      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/labels"])
      assert upstream_calls(context) == 2
    end

    # The trap this pair exists for: an Elixir writer and a shell reader that
    # disagree on where a resource lives give a cache that is always cold and
    # always looks healthy. So the identity is asserted from both ends against the
    # SAME resource — the directory the shell actually created, and the path the
    # Elixir side derives from `ResourceStore.key/4`.
    test "the daemon and the wrapper agree on where a resource lives", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      [{shape, body}] = cached_shapes(context)
      assert shape =~ ~r/\Aowner\/repo\/pr\/1670\/[0-9a-f]{64}\z/

      key = ResourceStore.key(:pull_request, "owner", "repo", 1670)

      assert AgentCache.resource_dir(key, state_dir: cache_state_dir(context)) ==
               Path.dirname(body)
    end

    test "a resource the daemon spells differently still resolves to one place", context do
      # `ResourceStore.key/4` down-cases owner and repo because the pipes disagree
      # on casing. The wrapper's directories are the same identity, so the store's
      # spelling must land on them.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      [{_shape, body}] = cached_shapes(context)

      key = ResourceStore.key(:pull_request, "OWNER", "Repo", "1670")

      assert AgentCache.resource_dir(key, state_dir: cache_state_dir(context)) ==
               Path.dirname(body)
    end

    # The freshness window is the only thing standing between a kept answer and a
    # wrong one for everything the daemon does not hear about, so it gets asserted
    # rather than assumed. Without this an entry could be kept for a month and
    # every other test in this block would still pass.
    test "an answer is not served once its window has closed", context do
      env = [AIUR_GITHUB_STATE_CACHE_TTL_MS: "1000"]

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], env)
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], env)
      assert upstream_calls(context) == 1

      # Past the window. Entry stamps are whole seconds, so the wait is two.
      Process.sleep(2_100)

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], env)
      assert upstream_calls(context) == 2
    end

    test "a window below the resolution of an entry stamp keeps nothing", context do
      env = [AIUR_GITHUB_STATE_CACHE_TTL_MS: "500"]

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], env)
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], env)

      assert upstream_calls(context) == 2
    end

    # R10. These reads decide whether to merge and whether CI passed. They cannot
    # be repaired after the fact and nothing invalidates them — a `git push` and a
    # completing check run never pass through this wrapper — so they are refused
    # outright rather than given a short window.
    test "a CI verdict is never served from the store", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "checks", "1670", "--json", "name,state"])
      assert {_, 0} = run_cached_guard(context, ["pr", "checks", "1670", "--json", "name,state"])

      assert upstream_calls(context) == 2
    end

    test "a merge decision is never served from the store", context do
      for fields <- ["statusCheckRollup", "mergeable,mergeStateStatus", "body,state", "reviewDecision"] do
        File.rm(context.calls)

        assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", fields])
        assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", fields])

        assert upstream_calls(context) == 2, "#{fields} was served from the store"
      end
    end

    test "a field set carrying no verdict is still shared", context do
      # The exclusion must be the named fields, not `--json` in general.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body,title,author"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body,title,author"])

      assert upstream_calls(context) == 1
    end

    test "two credentials never share one answer", context do
      first = [AIUR_GITHUB_BUDGET_KEY: "c" <> String.duplicate("0", 63)]
      second = [AIUR_GITHUB_BUDGET_KEY: "d" <> String.duplicate("0", 63)]
      args = ["pr", "view", "1670", "--json", "body"]

      assert {_, 0} = run_cached_guard(context, args, broker_env(context) ++ first)
      assert {_, 0} = run_cached_guard(context, args, broker_env(context) ++ second)

      # A response body is identity-dependent — a private repository one token
      # cannot see, a `permissions` object, a collaborator list.
      assert upstream_calls(context) == 2
    end

    test "editing a comment does not flush the whole repository", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1671", "--json", "body"])
      assert upstream_calls(context) == 2

      # How an agent updates its workpad. The comment id is not a ticket number,
      # so the resource it belongs to cannot be named — but agents do this every
      # few minutes, and retiring the repository for it would flush the store
      # continuously and the sharing would never happen.
      assert {_, 0} =
               run_cached_guard(context, [
                 "api",
                 "-X",
                 "PATCH",
                 "repos/owner/repo/issues/comments/99001",
                 "-f",
                 "body=updated"
               ])

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1671", "--json", "body"])

      assert upstream_calls(context) == 3
    end

    test "an agent that opts out of reading still retires what it changes", context do
      # The store is shared by the whole host. One process declining to read from
      # it must not leave every other agent replaying an answer it just replaced.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert upstream_calls(context) == 1

      assert {_, 0} =
               run_cached_guard(context, ["issue", "comment", "1670", "--body", "hi"], AIUR_GITHUB_STATE_CACHE_ENABLED: "0")

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert upstream_calls(context) == 3
    end

    test "a write against another GitHub deployment retires nothing here", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["issue", "comment", "1670", "--hostname", "ghe.example.com", "--body", "hi"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      assert upstream_calls(context) == 2
    end

    test "naming the default host explicitly is not another deployment", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["issue", "comment", "1670", "--hostname", "github.com", "--body", "hi"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      assert upstream_calls(context) == 3
    end

    test "a REST read with a query string is still filed under its resource", context do
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/pulls/1670?per_page=1"])
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/pulls/1670?per_page=1"])
      assert upstream_calls(context) == 1

      assert :ok = AgentCache.invalidate("owner/repo", 1670, state_dir: cache_state_dir(context))

      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/pulls/1670?per_page=1"])
      assert upstream_calls(context) == 2
    end

    test "a vanished body falls through instead of answering with nothing", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      [{_shape, body}] = cached_shapes(context)

      # The entry's stamp survives its body — the window between a writer removing
      # a body it could not commit and the reader that already passed the
      # readability check.
      File.rm!(body)

      assert {output, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      assert output != ""
      assert upstream_calls(context) == 2
    end

    test "the merge gate still refuses with the store enabled", context do
      assert {output, 77} = run_cached_guard(context, ["pr", "merge", "1670", "--squash"])

      assert output =~ "agents cannot approve or merge pull requests"
      refute File.exists?(context.calls)
    end

    test "the dispatch-disposition gate still refuses with the store enabled", context do
      assert {output, 78} = run_cached_guard(context, ["issue", "create", "--title", "t", "--body", "b"])

      assert output =~ "no dispatch disposition"
      refute File.exists?(context.calls)
    end
  end

  defp cache_state_dir(context), do: Path.join(context.workspace, "budget-state")

  # The workspace anchor requires the process to actually be inside the
  # workspace, and a shell derives `$PWD` at startup, so both are supplied.
  defp run_cached_guard(context, args, extra_env \\ [], opts \\ []) do
    directory = Keyword.get(opts, :cd, context.workspace)

    base = [
      {"AIUR_GITHUB_BUDGET_ROOT", cache_state_dir(context)},
      {"AIUR_GITHUB_BUDGET_ENABLED", "0"},
      {"AIUR_GITHUB_REPO", "owner/repo"},
      {"PWD", directory}
    ]

    # Merged by name rather than appended, so a test enabling the broker replaces
    # the default instead of relying on which duplicate the port layer keeps.
    overrides = Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)
    env = Enum.reject(base, fn {name, _value} -> List.keymember?(overrides, name, 0) end) ++ overrides

    System.cmd(context.wrapper, args, env: guard_env(context) ++ env, cd: directory, stderr_to_stdout: true)
  end

  # The shared admission broker, which is what makes one fetcher out of many
  # simultaneous identical readers. Every other cache test runs without it,
  # because caching must work whether or not the broker is available.
  defp broker_token_key, do: "b" <> String.duplicate("0", 63)

  defp broker_env(context) do
    [
      AIUR_GITHUB_BUDGET_ENABLED: "1",
      AIUR_GITHUB_BUDGET_KEY: broker_token_key(),
      AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace)
    ]
  end

  # `FAKE_GH_SLEEP` holds the leader's call open long enough that every follower
  # is genuinely in flight while it runs. Without an overlap there is no
  # coalescing to observe, only caching.
  defp concurrent_reads(context, args, count) do
    env =
      broker_env(context) ++
        [
          FAKE_GH_SLEEP: "1",
          # Concurrency limits deliberately raised past the reader count and the
          # stagger removed. Left at their defaults the in-flight ceiling would
          # serialise most of these readers, and the later ones would be answered
          # by the stored entry — so the test would pass on caching alone and say
          # nothing about coalescing. With every reader admissible at once, the
          # only thing that can hold the count at one is the claim.
          AIUR_GITHUB_MAX_INFLIGHT: Integer.to_string(count + 1),
          AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT: Integer.to_string(count + 1),
          AIUR_GITHUB_REQUESTS_PER_MINUTE: "600",
          AIUR_GITHUB_STAGGER_MS: "0"
        ]

    1..count
    |> Task.async_stream(fn _index -> run_cached_guard(context, args, env) end,
      max_concurrency: count,
      timeout: 120_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # Rows the wrapper wrote to its own effectiveness log, by outcome.
  defp cache_events(context, outcome) do
    [context.state_path, "github-quota", "agent-cache.tsv"]
    |> Path.join()
    |> File.read()
    |> case do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.count(fn row -> row |> String.split("\t") |> Enum.at(2) == outcome end)

      _missing ->
        0
    end
  end

  # Each stored answer as the broker names it: `owner/repo/kind/id/<shape>`.
  defp cached_shapes(context) do
    [cache_state_dir(context), "state-cache/v1/**/*.body"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(fn body ->
      key =
        body
        |> Path.relative_to(Path.join(cache_state_dir(context), "state-cache/v1"))
        |> String.replace_suffix(".body", "")

      {key, body}
    end)
  end

  defp upstream_calls(context), do: line_count(context.calls)

  defp line_count(path) do
    case File.read(path) do
      {:ok, contents} -> contents |> String.split("\n", trim: true) |> length()
      _missing -> 0
    end
  end

  defp run_guard(context, args, extra_env \\ []) do
    extra_env = Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)

    budget_env =
      if Enum.any?(extra_env, fn
           {"AIUR_GITHUB_BUDGET_ROOT", value} -> value != ""
           _other -> false
         end),
         do: [{"AIUR_GITHUB_BUDGET_ENABLED", "1"}],
         else: []

    System.cmd(context.wrapper, args,
      env: guard_env(context) ++ budget_env ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp run_agent_guard(context, args, env) do
    System.cmd(context.wrapper, args, env: env, stderr_to_stdout: true)
  end

  # The same script run from outside `.aiur-runtime/bin` and without the agent
  # workspace marker: this is how the Executor invokes it, with full authority.
  defp run_executor_guard(context, args, extra_env) do
    bin = Path.join(context.workspace, "executor-bin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)
    wrapper = Path.join(bin, "gh")
    File.cp!(context.wrapper, wrapper)
    File.chmod!(wrapper, 0o755)

    env =
      Enum.reject(guard_env(context), fn {name, _value} -> name == "AIUR_AGENT_WORKSPACE" end) ++
        [{"AIUR_GITHUB_BUDGET_ENABLED", "1"}] ++
        Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)

    System.cmd(wrapper, args, env: env, stderr_to_stdout: true)
  end

  defp run_git_credential(context, input, extra_env) do
    env =
      [{"AIUR_REAL_GIT", real_git()}] ++
        Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)

    System.cmd("sh", ["-c", ~s(printf '%s' "$2" | "$1" credential fill), "sh", context.git_wrapper, input],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp run_git_guard(context, args, extra_env \\ []) do
    extra_env = Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)

    System.cmd(context.git_wrapper, args,
      cd: context.workspace,
      env:
        [
          {"AIUR_REAL_GIT", real_git()},
          {"AIUR_AGENT_WORKSPACE", context.workspace},
          {"GITHUB_TOKEN", "agent-token"}
        ] ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp init_git_workspace(context) do
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", context.workspace], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", context.workspace, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", context.workspace, "config", "user.name", "Test"], stderr_to_stdout: true)
    File.write!(Path.join(context.workspace, "tracked.txt"), "tracked\n")
    assert {_, 0} = System.cmd(real_git(), ["-C", context.workspace, "add", "tracked.txt"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", context.workspace, "commit", "--quiet", "-m", "initial"], stderr_to_stdout: true)
  end

  # A linked worktree of the agent workspace itself, so
  # `-C workspace worktree remove <it>` passes the #2049 workspace-authority
  # check and reaches the #2094 liveness and uncommitted-changes checks.
  defp make_workspace_worktree(context, name) do
    init_git_workspace(context)
    worktree = Path.join(context.workspace, name)

    assert {_, 0} =
             System.cmd(real_git(), ["-C", context.workspace, "worktree", "add", "--quiet", worktree, "-b", name], stderr_to_stdout: true)

    worktree
  end

  # A wrapper installed outside `<workspace>/.aiur-runtime/bin`, the shape the
  # host-level install (`~/.aiur/bin/git`, alongside `aiurdev`) takes for a
  # plain-shell caller. Returns the host bin directory so the caller can prepend
  # it to PATH exactly as an operator shell would.
  defp install_host_wrapper(context) do
    host_bin = Path.join(context.workspace, "host-bin")
    File.mkdir_p!(host_bin)
    host_wrapper = Path.join(host_bin, "git")
    File.cp!(context.git_wrapper, host_wrapper)
    File.chmod!(host_wrapper, 0o755)
    host_bin
  end

  defp make_host_worktree(context) do
    main = Path.join(context.workspace, "host-main")
    File.mkdir_p!(main)
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", main], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", main, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", main, "config", "user.name", "Test"], stderr_to_stdout: true)
    File.write!(Path.join(main, "tracked.txt"), "tracked\n")
    assert {_, 0} = System.cmd(real_git(), ["-C", main, "add", "tracked.txt"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", main, "commit", "--quiet", "-m", "initial"], stderr_to_stdout: true)
    worktree = Path.join(main, "wt")
    assert {_, 0} = System.cmd(real_git(), ["-C", main, "worktree", "add", "--quiet", worktree, "-b", "wt"], stderr_to_stdout: true)
    {main, worktree}
  end

  # Invoke `git` the way a plain operator shell would: the host bin directory
  # prepended to PATH so the bare `git` resolves to the host wrapper, and no
  # AIUR_REAL_GIT or workspace marker. The wrapper resolves the real executable
  # from the rest of PATH on its own.
  defp run_host_guard(host_bin, main, args) do
    script = "exec git " <> Enum.map_join(args, " ", &shell_quote/1)

    System.cmd("sh", ["-c", script],
      cd: main,
      env: [
        {"PATH", host_bin <> ":" <> (System.get_env("PATH") || "")},
        {"AIUR_REAL_GIT", nil}
      ],
      stderr_to_stdout: true
    )
  end

  defp shell_quote(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  # A "sibling wrapper" process rooted in a worktree: the spawned command line
  # never mentions git or worktree, which is precisely the shape that defeats
  # naive `/proc/*/cmdline` matching. `exec` replaces the shell, so the port's
  # OS pid IS the rooted process.
  defp spawn_rooted_sibling(worktree, command) do
    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [:binary, args: ["-c", "cd \"$1\" && exec $2", "sh", worktree, command]]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)
    {port, pid}
  end

  defp wait_rooted(pid, worktree, attempts \\ 200)

  defp wait_rooted(_pid, _worktree, 0), do: flunk("sibling wrapper never rooted in the worktree")

  defp wait_rooted(pid, worktree, attempts) do
    case File.read_link("/proc/#{pid}/cwd") do
      {:ok, cwd} when is_binary(cwd) ->
        if Path.expand(cwd) == Path.expand(worktree) do
          :ok
        else
          Process.sleep(10)
          wait_rooted(pid, worktree, attempts - 1)
        end

      _ ->
        Process.sleep(10)
        wait_rooted(pid, worktree, attempts - 1)
    end
  end

  defp stop_rooted_sibling(_port, pid) do
    # The port closes with its owning test process; only the rooted process
    # needs an explicit kill, and `kill` by pid works from any process, so the
    # on_exit callback can reuse this without touching the dead owner's port.
    _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp real_git, do: System.get_env("AIUR_REAL_GIT") || System.find_executable("git")

  defp guard_env(context) do
    [
      {"AIUR_REAL_GH", context.fake_gh},
      {"AIUR_REPO_STATE_PATH", context.state_path},
      {"AIUR_AGENT_QUOTA_STATE_PATH", Path.join(context.state_path, "github-quota")},
      {"AIUR_AGENT_WORKSPACE", context.workspace},
      {"FAKE_GH_CALLS", context.calls},
      {"GITHUB_TOKEN", ""},
      {"AIUR_GITHUB_BUDGET_ENABLED", "0"},
      {"AIUR_GITHUB_BUDGET_ROOT", ""},
      {"AIUR_GITHUB_BUDGET_KEY", ""},
      {"AIUR_GITHUB_BUDGET_BROKER", "/nonexistent/aiur-github-budget"}
    ]
  end

  defp isolated_command_path(context, extra_commands) do
    bin = Path.join(context.workspace, "isolated-command-path-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)

    commands =
      ~w(awk basename cat cut date dirname grep mkdir mktemp mv rm sed sleep tail wc) ++
        extra_commands

    Enum.each(commands, fn command ->
      executable = System.find_executable(command) || flunk("#{command} executable is required for this guard test")
      File.ln_s!(executable, Path.join(bin, command))
    end)

    bin
  end

  defp wait_for_calls(path, expected, attempts \\ 50)

  defp wait_for_calls(_path, _expected, 0), do: flunk("timed out waiting for guarded gh call")

  defp wait_for_calls(path, expected, attempts) do
    calls =
      case File.read(path) do
        {:ok, contents} -> String.split(contents, "\n", trim: true) |> length()
        _missing -> 0
      end

    if calls >= expected do
      :ok
    else
      Process.sleep(10)
      wait_for_calls(path, expected, attempts - 1)
    end
  end
end
