defmodule Aiur.GitHub.BudgetSharedTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentGitHubGuard.AgentToken
  alias Aiur.GitHub.AgentBudgetCommand
  alias Aiur.GitHub.Budget
  alias Aiur.GitHub.Budget.Shared
  alias Aiur.GitHub.BudgetTestSupport
  alias Aiur.TestCleanup

  setup do
    BudgetTestSupport.setup()
  end

  test "a failed shared hold read falls through to per-instance local limits" do
    request = %{url: "https://api.github.com/repos/owner/repo/issues"}

    assert :clear =
             Shared.hold_status(request, "credential-key",
               coordination_status_fun: fn -> %{available?: true, live_count: 3} end,
               github_budget_hold_fun: fn _credential, _resource ->
                 {:error, {:store_unavailable, :connection_lost}}
               end
             )

    assert {300, 150, 75} =
             Shared.fallback_limits({300, 150, 75}, %{available?: false, live_count: 3}, false)

    assert {100, 50, 25} =
             Shared.fallback_limits({300, 150, 75}, %{available?: false, live_count: 3}, true)

    assert {50, 25, 12} =
             Shared.fallback_limits({100, 50, 25}, %{available?: false, live_count: 1}, true)
  end

  test "two daemon budget clients share one admission ceiling" do
    {:ok, store} = Agent.start_link(fn -> 0 end)
    reset_at = DateTime.add(DateTime.utc_now(), 3_600, :second)

    admit = fn _lease_id, _credential, "graphql", _consumer, limit, points ->
      Agent.get_and_update(store, fn used ->
        if used + points <= limit do
          {{:ok, :admitted}, used + points}
        else
          {{:ok, {:held, reset_at}}, used}
        end
      end)
    end

    opts = [
      coordination_status_fun: fn -> %{available?: true, live_count: 2} end,
      github_budget_admit_fun: admit,
      request_points: 60,
      release_fun: fn _lease_id, _key -> :ok end,
      consumer_key: "daemon:test",
      daemon_graphql_limit_per_hour: 100
    ]

    first = %{url: "https://api.github.com/graphql", credential_key: "shared-app-credential"}
    second = %{url: "https://api.github.com/graphql", credential_key: "shared-app-credential"}

    assert {:ok, %{id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}} =
             Shared.grant_or_hold("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", first, "credential", opts)

    assert {:hold, %{reason: :shared_budget, reset_at: ^reset_at}} =
             Shared.grant_or_hold("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", second, "credential", opts)

    assert Agent.get(store, & &1) == 60
  end

  test "agent hold reports broker unavailable when the broker bypasses", %{root: root} do
    budget_root = Path.join(root, "ledger")
    token_path = Path.join(budget_root, "agent-token")
    previous_budget_root = Application.get_env(:aiur, :github_budget_dir)
    File.mkdir_p!(budget_root)
    Application.put_env(:aiur, :github_budget_dir, budget_root)
    assert :ok = AgentToken.ensure(path: token_path, token: "agent-pat")

    on_exit(fn ->
      if previous_budget_root do
        Application.put_env(:aiur, :github_budget_dir, previous_budget_root)
      else
        Application.delete_env(:aiur, :github_budget_dir)
      end

      TestCleanup.rm_rf!(Path.join(root, "ledger"))
    end)

    assert {:error, :github_budget_broker_unavailable} =
             AgentBudgetCommand.execute(
               ["hold", "--scope", "token", "--resource", "core", "--delay-ms", "1000"],
               python: nil
             )
  end

  test "agent-side admissions retain separate workspace actors in the shared store" do
    root = Path.join(System.tmp_dir!(), "agent-budget-socket-#{System.unique_integer([:positive])}")
    budget_root = Path.join(root, "ledger")
    token_path = Path.join(budget_root, "agent-token")
    previous_budget_root = Application.get_env(:aiur, :github_budget_dir)
    File.mkdir_p!(budget_root)
    Application.put_env(:aiur, :github_budget_dir, budget_root)
    assert :ok = AgentToken.ensure(path: token_path, token: "agent-pat")

    on_exit(fn ->
      if previous_budget_root, do: Application.put_env(:aiur, :github_budget_dir, previous_budget_root), else: Application.delete_env(:aiur, :github_budget_dir)
      TestCleanup.rm_rf!(root)
    end)

    {:ok, state} = Agent.start_link(fn -> %{used: 0, actors: []} end)

    acquire_command = fn _args, _token_key, _opts ->
      id = "a" <> String.duplicate("b", 31)
      {:ok, "granted #{id}"}
    end

    admit = fn _id, _credential, resource, consumer, limit, _points ->
      Agent.get_and_update(state, fn %{used: used, actors: actors} = current ->
        next = %{current | actors: [consumer | actors]}

        if resource == "core" and used < limit do
          {{:ok, :admitted}, %{next | used: used + 1}}
        else
          {{:ok, {:held, DateTime.add(DateTime.utc_now(), 3_600, :second)}}, next}
        end
      end)
    end

    shared_opts = [
      coordination_status_fun: fn -> %{available?: true, live_count: 2} end,
      github_budget_admit_fun: admit,
      acquire_command_fun: acquire_command,
      release_fun: fn _id, _key -> :ok end,
      agent_core_limit_per_hour: 1
    ]

    first_label = "workspace:/instance-one/issue-1"
    second_label = "workspace:/instance-two/issue-2"

    assert {:ok, "granted " <> _} = AgentBudgetCommand.execute(agent_acquire_args(first_label), shared_opts)
    assert {:ok, "hold shared core " <> _} = AgentBudgetCommand.execute(agent_acquire_args(second_label), shared_opts)

    expected = Enum.map([first_label, second_label], &Budget.token_key/1) |> Enum.sort()
    assert Enum.sort(Agent.get(state, & &1.actors)) == expected
    assert Agent.get(state, & &1.used) == 1
  end

  defp agent_acquire_args(label) do
    [
      "acquire",
      "--resource",
      "core",
      "--consumer-key",
      Budget.token_key(label),
      "--consumer-label",
      label,
      "--endpoint-family",
      "issues",
      "--max-inflight",
      "4",
      "--max-inflight-per-endpoint",
      "2",
      "--requests-per-minute",
      "300",
      "--stagger-ms",
      "0",
      "--lease-ttl-ms",
      "35000",
      "--core-limit",
      "1",
      "--graphql-limit",
      "0",
      "--search-limit",
      "0"
    ]
  end

  test "a shared admission outage releases the lease for a divided local retry" do
    parent = self()

    assert :retry_fallback =
             Shared.grant_or_hold(
               "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               %{url: "https://api.github.com/graphql"},
               "credential",
               coordination_status_fun: fn -> %{available?: true, live_count: 2} end,
               github_budget_admit_fun: fn _, _, _, _, _, _ -> {:error, :database_down} end,
               release_fun: fn lease_id, _key -> send(parent, {:released, lease_id}) end
             )

    assert_receive {:released, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, 1_000
  end

  test "Budget retries a failed shared admission under the divided local ceiling", %{root: root} do
    {:ok, shared_attempts} = Agent.start_link(fn -> 0 end)
    {:ok, acquire_calls} = Agent.start_link(fn -> 0 end)

    test_pid = self()

    request = %{token: "retry-fallback-token", url: "https://api.github.com/graphql"}

    opts = [
      state_dir: root,
      enabled?: true,
      stagger_ms: 0,
      consumer_key: "daemon:retry-test",
      daemon_graphql_limit_per_hour: 100,
      coordination_status_fun: fn -> %{available?: true, live_count: 2} end,
      coordination_configured_fun: fn -> true end,
      acquire_command_fun: fn args, _key, _opts ->
        send(test_pid, {:local_acquire_args, args})

        id =
          Agent.get_and_update(acquire_calls, fn
            0 -> {"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 1}
            1 -> {"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 2}
          end)

        {:ok, "granted " <> id}
      end,
      release_fun: fn _lease_id, _key -> :ok end,
      github_budget_admit_fun: fn _lease, _credential, resource, _consumer, limit, _points ->
        send(test_pid, {:shared_admission_attempt, resource, limit})

        Agent.get_and_update(shared_attempts, fn
          0 -> {{:error, :database_down}, 1}
          count -> {{:ok, :admitted}, count + 1}
        end)
      end
    ]

    assert {:ok, _lease} = Budget.acquire(request, opts)
    assert_receive {:shared_admission_attempt, "graphql", 100}, 1_000
    assert_receive {:local_acquire_args, first_args}, 1_000
    assert_receive {:local_acquire_args, retry_args}, 1_000
    assert option_value(first_args, "--graphql-limit") == "100"
    assert option_value(retry_args, "--graphql-limit") == "50"
    assert Agent.get(shared_attempts, & &1) == 1
  end

  defp option_value(args, option) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^option, value] -> value
      _other -> nil
    end)
  end
end
