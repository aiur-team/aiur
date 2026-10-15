defmodule Aiur.AgentGitHubGuard.GraphqlAndPagination2Test do
  use Aiur.AgentGitHubGuardCase, async: true

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

  test "a silent broker failure is named rather than left blank", context do
    budget_root = Path.join(context.state_path, "silent-broker-budget")
    silent_broker = Path.join(context.state_path, "silent-broker.py")
    File.mkdir_p!(context.state_path)
    File.write!(silent_broker, "import sys\nsys.exit(1)\n")
    File.chmod!(silent_broker, 0o755)

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: silent_broker,
               GITHUB_TOKEN: "shared-test-credential"
             )

    # A subprocess killed by a signal says nothing, and an empty parenthesis
    # reads as though the wrapper had no idea it was there.
    assert output =~ "broker exited non-zero without output"
    refute File.exists?(context.calls)
  end

  test "a broker that cannot reach its storage still gets the recovery configuration", context do
    budget_root = Path.join(context.state_path, "unreachable-budget")
    unreachable_broker = Path.join(context.state_path, "unreachable-broker.py")
    File.mkdir_p!(context.state_path)
    File.write!(unreachable_broker, "import sys\nprint('unable to open database file', file=sys.stderr)\nsys.exit(1)\n")
    File.chmod!(unreachable_broker, 0o755)

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: unreachable_broker,
               GITHUB_TOKEN: "shared-test-credential"
             )

    # Dropping the confident misdiagnosis must not drop the advice from the one
    # failure it does diagnose: a budget root the sandbox never granted is
    # exactly what the ownership/permissions recovery text repairs.
    assert output =~ "unable to open database file"
    assert output =~ "agent.codex.turn_sandbox_policy.writableRoots"
    refute File.exists?(context.calls)
  end
end
