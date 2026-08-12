defmodule Aiur.AgentGitHubGuardTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Aiur.AgentGitHubGuard
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
                  http://127.0.0.1:*) fake_probe_url=$(printf '%s' "$fake_arg" | sed 's#/[A-Za-z0-9_-]*/0$#/not-the-capability/0#') ;;
                esac
              done
              "$FAKE_GH_NATIVE" api "$fake_probe_url" --silent >/dev/null 2>&1
              printf '%s\n' "$?" > "$FAKE_GH_REPLAY_PROBE"
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
               timeout_ms: 10
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

    timeout = System.find_executable("timeout") || flunk("timeout executable is required for this Linux-only guard test")

    assert {_output, 124} =
             System.cmd(timeout, ["0.2", context.wrapper, "pr", "view", "1670"],
               env:
                 guard_env(context) ++
                   [
                     {"AIUR_GITHUB_BUDGET_ROOT", budget_root},
                     {"AIUR_GITHUB_BUDGET_KEY", key},
                     {"AIUR_GITHUB_BUDGET_BROKER", broker}
                   ],
               stderr_to_stdout: true
             )

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

    assert {output, 64} =
             run_guard(context, ["api", "graphql", "--paginate", "-f", "query=@#{query}"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace)
             )

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
               GH_TOKEN: "guard-token",
               GITHUB_TOKEN: "github-token",
               HTTP_PROXY: "http://127.0.0.1:1",
               NO_PROXY: "not-localhost",
               no_proxy: "not-localhost",
               PATH: "#{Path.dirname(context.fake_jq)}:#{System.get_env("PATH")}"
             )

    rendered_command = File.read!(renderer_args)
    assert rendered_command =~ "api http://127.0.0.1:"
    assert rendered_command =~ "--jq length"
    assert File.read!(replay_probe) == "1\n"
    assert File.read!(renderer_env) == "GH_TOKEN=\nGITHUB_TOKEN=\nNO_PROXY=127.0.0.1,localhost\nno_proxy=127.0.0.1,localhost\n"

    [replay_url] =
      Regex.run(~r/api (http:\/\/127\.0\.0\.1:\d+\/[A-Za-z0-9_-]+\/0)/, rendered_command, capture: :all_but_first)

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
               timeout_ms: 10
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

    assert {_, 0} = System.cmd("git", ["init", repo], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", repo, "remote", "add", "origin", "https://agent:embedded-token@github.com/owner/repo.git"],
               stderr_to_stdout: true
             )

    {output, exit_code} =
      System.cmd(context.git_wrapper, ["push", "--dry-run", "origin", "HEAD"],
        cd: repo,
        env: [{"AIUR_REAL_GIT", System.find_executable("git")}, {"GITHUB_TOKEN", "agent-token"}],
        stderr_to_stdout: true
      )

    assert exit_code == 64
    assert output =~ "credential-free https://github.com remote"
    refute output =~ "embedded-token"
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

  defp run_guard(context, args, extra_env \\ []) do
    System.cmd(context.wrapper, args,
      env: guard_env(context) ++ Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end),
      stderr_to_stdout: true
    )
  end

  defp run_git_credential(context, input, extra_env) do
    env =
      [{"AIUR_REAL_GIT", System.find_executable("git")}] ++
        Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)

    System.cmd("sh", ["-c", ~s(printf '%s' "$2" | "$1" credential fill), "sh", context.git_wrapper, input],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp guard_env(context) do
    [
      {"AIUR_REAL_GH", context.fake_gh},
      {"AIUR_REPO_STATE_PATH", context.state_path},
      {"AIUR_AGENT_QUOTA_STATE_PATH", Path.join(context.state_path, "github-quota")},
      {"AIUR_AGENT_WORKSPACE", context.workspace},
      {"FAKE_GH_CALLS", context.calls},
      {"GITHUB_TOKEN", ""},
      {"AIUR_GITHUB_BUDGET_ROOT", ""},
      {"AIUR_GITHUB_BUDGET_KEY", ""},
      {"AIUR_GITHUB_BUDGET_BROKER", "/nonexistent/aiur-github-budget"}
    ]
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
