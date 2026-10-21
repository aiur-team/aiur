defmodule Aiur.AgentGitHubGuard.GraphqlAndPagination1Test do
  use Aiur.AgentGitHubGuardCase, async: true

  # The family/bucket split this issue exists for: `pr view|list|status|checks`,
  # `issue view|list|status`, and `search` all speak GraphQL on the wire and must
  # be booked to the graphql resource — not core. They KEEP their descriptive
  # families (pulls / issues / search) so the lease pool and the audit histogram
  # stay separated — the broker's hourly accounting buckets on the booked
  # `resource`, not on the family. The broker records the `resource` the guard
  # booked each admission to, so a regression that books `pr view` to core fails
  # here on `resource`, and a regression that collapses every GraphQL arm onto
  # one family (merging the lease pools) fails here on `endpoint_family`.
  test "high-level GraphQL commands book the graphql resource, not core", context do
    budget_root = Path.join(context.state_path, "graphql-read-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    env = [
      AIUR_GITHUB_BUDGET_ROOT: budget_root,
      AIUR_GITHUB_BUDGET_KEY: key,
      AIUR_GITHUB_BUDGET_BROKER: broker
    ]

    graphql_commands = [
      {["pr", "view", "1670"], "pulls"},
      {["pr", "list"], "pulls"},
      {["pr", "status"], "pulls"},
      {["pr", "checks", "1670"], "pulls"},
      {["issue", "view", "1670"], "issues"},
      {["issue", "list"], "issues"},
      {["issue", "status"], "issues"},
      {["search", "issues", "state:open"], "search"}
    ]

    for {args, _family} <- graphql_commands do
      assert {"ok\n", 0} = run_guard(context, args, env), "admission failed for #{inspect(args)}"
    end

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    admissions = Jason.decode!(snapshot)["admissions"]
    assert length(admissions) == length(graphql_commands)

    for {{_args, family}, admission} <- Enum.zip(graphql_commands, admissions) do
      assert admission["endpoint_family"] == family
      assert admission["resource"] == "graphql"
    end
  end

  # `gh search` splits across two wire transports (measured with `GH_DEBUG=api`):
  # `search issues|prs` are GraphQL, while `search repos|code|commits|users`
  # hit REST `/search/*`, which GitHub meters as a third pool, `search` (~30
  # req/min rather than 5,000/hr). Booking the search subcommands to core or
  # graphql mis-states the spend and paces nothing against the pool that
  # throttles first, so the `search` resource is its own bucket.
  test "gh search subcommands book the search resource, not core or graphql", context do
    budget_root = Path.join(context.state_path, "search-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    env = [
      AIUR_GITHUB_BUDGET_ROOT: budget_root,
      AIUR_GITHUB_BUDGET_KEY: key,
      AIUR_GITHUB_BUDGET_BROKER: broker
    ]

    search_commands = [
      ["search", "repos", "state:open"],
      ["search", "code", "foobar"],
      ["search", "commits", "fix"],
      ["search", "users", "everdred"]
    ]

    for args <- search_commands do
      assert {"ok\n", 0} = run_guard(context, args, env), "admission failed for #{inspect(args)}"
    end

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    admissions = Jason.decode!(snapshot)["admissions"]
    assert length(admissions) == length(search_commands)

    for admission <- admissions do
      assert admission["endpoint_family"] == "search"
      assert admission["resource"] == "search"
    end
  end

  test "REST high-level commands stay in the core bucket", context do
    budget_root = Path.join(context.state_path, "rest-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    env = [
      AIUR_GITHUB_BUDGET_ROOT: budget_root,
      AIUR_GITHUB_BUDGET_KEY: key,
      AIUR_GITHUB_BUDGET_BROKER: broker
    ]

    rest_commands = [
      # `pr diff` is REST even though `pr view|list|status|checks` are GraphQL.
      {["pr", "diff", "1670"], "pulls"},
      {["pr", "close", "1670"], "pulls"},
      {["issue", "edit", "1670", "--body", "x"], "issues"},
      {["issue", "comment", "1670", "--body", "x"], "issues"}
    ]

    for {args, _family} <- rest_commands do
      assert {"ok\n", 0} = run_guard(context, args, env), "admission failed for #{inspect(args)}"
    end

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    admissions = Jason.decode!(snapshot)["admissions"]
    assert length(admissions) == length(rest_commands)

    for {{_args, family}, admission} <- Enum.zip(rest_commands, admissions) do
      # REST commands book to core and keep their descriptive family. Asserting
      # the positive family (rather than `!= "graphql"`) makes this fail if a
      # future change ever moved `pr diff` into the graphql family.
      assert admission["endpoint_family"] == family
      assert admission["resource"] == "core"
    end
  end

  test "the GraphQL write subcommands book the graphql resource", context do
    budget_root = Path.join(context.state_path, "graphql-write-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    env = [
      AIUR_GITHUB_BUDGET_ROOT: budget_root,
      AIUR_GITHUB_BUDGET_KEY: key,
      AIUR_GITHUB_BUDGET_BROKER: broker
    ]

    # `pr create`, `pr merge`, `pr review`, and `issue create` mutate through
    # GraphQL. Merge and approve are agent-gated, so `pr merge` runs under the
    # Executor wrapper and `pr review` as a non-approving comment review.
    assert {"ok\n", 0} = run_guard(context, ["pr", "create", "--title", "x"], env)
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "--comment", "--body", "looks reasonable"], env)
    assert {"ok\n", 0} = run_guard(context, ["issue", "create", "--title", "x", "--label", "agent:todo"], env)
    assert {"ok\n", 0} = run_executor_guard(context, ["pr", "merge", "1670", "--squash"], env)

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    admissions = Jason.decode!(snapshot)["admissions"]
    assert length(admissions) == 4

    # The GraphQL write subcommands keep their descriptive family (pulls for
    # `pr create|review|merge`, issues for `issue create`) while booking the
    # graphql resource — the broker buckets the hourly accounting on `resource`.
    assert Enum.map(admissions, & &1["endpoint_family"]) == ["pulls", "pulls", "issues", "pulls"]

    for admission <- admissions do
      assert admission["resource"] == "graphql"
    end
  end

  test "pr view consumes the graphql actor ceiling, not the core one", context do
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    # The per-actor ceiling is keyed by the broker consumer. Pin it to one
    # literal so the invocations below are the same actor and the ceiling
    # accumulates deterministically in every environment. Relying on the ambient
    # AIUR_GITHUB_BUDGET_CONSUMER made this pass in agent workspaces (where it is
    # set) and fail in CI (where it is not).
    consumer = "pr-view-ceiling-test"

    # A graphql ceiling of 1: the second `pr view` holds, proving `pr view`
    # spends against the GraphQL budget. If it were still booked to core (the
    # pre-fix behaviour) this hold would never fire.
    graphql_budget = Path.join(context.state_path, "graphql-ceiling-budget")

    graphql_env = [
      AIUR_GITHUB_BUDGET_ROOT: graphql_budget,
      AIUR_GITHUB_BUDGET_KEY: key,
      AIUR_GITHUB_BUDGET_BROKER: broker,
      AIUR_GITHUB_BUDGET_CONSUMER: consumer,
      AIUR_GITHUB_GRAPHQL_LIMIT_PER_HOUR: "1",
      AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "0"
    ]

    assert {"ok\n", 0} = run_guard(context, ["pr", "view", "1670"], graphql_env)
    assert "wait actor " <> _ms = run_held_guard(context, ["pr", "view", "1670"], graphql_env)
    assert File.read!(context.calls) == "pr view\n"

    # A core ceiling of 1 with the graphql ceiling disabled: `pr view` is
    # admitted repeatedly because it never touches the core budget.
    core_budget = Path.join(context.state_path, "core-ceiling-budget")

    core_env = [
      AIUR_GITHUB_BUDGET_ROOT: core_budget,
      AIUR_GITHUB_BUDGET_KEY: key,
      AIUR_GITHUB_BUDGET_BROKER: broker,
      AIUR_GITHUB_BUDGET_CONSUMER: consumer,
      AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "1",
      AIUR_GITHUB_GRAPHQL_LIMIT_PER_HOUR: "0"
    ]

    assert {"ok\n", 0} = run_guard(context, ["pr", "view", "1670"], core_env)
    assert {"ok\n", 0} = run_guard(context, ["pr", "view", "1670"], core_env)
  end

  test "a search subcommand consumes the search actor ceiling, not the core one", context do
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    # `gh search repos` is metered as `search` (~30 req/min), its own pool, so
    # it must spend against a search ceiling rather than the core or graphql
    # windows. A search limit of 1 holds the second call; if `search repos` were
    # still booked to core or graphql this hold would never fire.
    consumer = "search-ceiling-test"
    search_budget = Path.join(context.state_path, "search-ceiling-budget")

    search_env = [
      AIUR_GITHUB_BUDGET_ROOT: search_budget,
      AIUR_GITHUB_BUDGET_KEY: key,
      AIUR_GITHUB_BUDGET_BROKER: broker,
      AIUR_GITHUB_BUDGET_CONSUMER: consumer,
      AIUR_GITHUB_SEARCH_LIMIT_PER_HOUR: "1",
      AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "0",
      AIUR_GITHUB_GRAPHQL_LIMIT_PER_HOUR: "0"
    ]

    assert {"ok\n", 0} = run_guard(context, ["search", "repos", "state:open"], search_env)
    assert "wait actor " <> _ms = run_held_guard(context, ["search", "repos", "state:open"], search_env)
    assert File.read!(context.calls) == "search repos\n"
  end

  # A proxy turns a real broker wait into an unusable response so this test can
  # observe the hold without killing a process during its sleep.
  defp run_held_guard(context, args, env) do
    proxy = Path.join(context.state_path, "hold-proxy-broker.py")
    holds = Path.join(context.state_path, "broker-holds")
    File.mkdir_p!(context.state_path)

    File.write!(proxy, """
    import os, subprocess, sys
    result = subprocess.run([sys.executable, os.environ["HOLD_PROXY_REAL_BROKER"], *sys.argv[1:]], capture_output=True, text=True)
    sys.stderr.write(result.stderr)
    if sys.argv[1] == "acquire" and result.stdout.startswith("wait"):
        with open(os.environ["HOLD_PROXY_HOLDS"], "a") as holds:
            holds.write(result.stdout)
        print("wait 0")
        sys.exit(0)
    sys.stdout.write(result.stdout)
    sys.exit(result.returncode)
    """)

    File.chmod!(proxy, 0o755)

    proxy_env =
      Keyword.merge(env,
        AIUR_GITHUB_BUDGET_BROKER: proxy,
        HOLD_PROXY_REAL_BROKER: Keyword.fetch!(env, :AIUR_GITHUB_BUDGET_BROKER),
        HOLD_PROXY_HOLDS: holds
      )

    assert {output, 75} = run_guard(context, args, proxy_env)
    assert output =~ "invalid or unusable wait response"
    String.trim(File.read!(holds))
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
end
