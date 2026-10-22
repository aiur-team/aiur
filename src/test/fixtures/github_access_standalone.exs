import ExUnit.Assertions
alias Aiur.GitHub.Access.{Settings, StaticSettings}
alias Aiur.GitHub.{Budget, BudgetBroker, ReadCache, ResourceStore}

[root] = System.argv()
Application.load(:aiur)
Application.ensure_all_started(:crypto)
Application.ensure_all_started(:telemetry)
Application.put_env(:aiur, :github_access_settings_provider, Aiur.GitHub.AccessSettings)
Application.put_env(:aiur, :workflow_file_path, Path.join(root, "missing-workflow.yaml"))

assert_raise ArgumentError, fn ->
  Aiur.GitHub.EventSourcePolicy.self_authored?("ticket.1.comment", "daemon[bot]", %{})
end

assert %Aiur.GitHub.Access.Settings{config_error: reason} = Aiur.GitHub.AccessSettings.settings()
refute is_nil(reason)
assert_raise ArgumentError, ~r/invalid GitHub config/, fn -> Aiur.GitHub.Access.Token.app_account() end
assert_raise ArgumentError, ~r/invalid GitHub config/, fn -> Aiur.GitHub.Access.Token.daemon_account() end
Application.put_env(:aiur, :github_access_settings_provider, StaticSettings)
Application.put_env(:aiur, :github_access_settings, Settings.new(root, repo: "o/r", budget: %{stagger_ms: 0}))
# Poison the domain paths: a forgotten Config.Paths read must fail the path assertion.
Application.put_env(:aiur, :decision_state_dir, Path.join(root, "wrong-domain-root"))
Application.put_env(:aiur, :github_budget_dir, Path.join(root, "wrong-budget-root"))
refute List.keymember?(Application.started_applications(), :aiur, 0)
refute Process.whereis(Aiur.WorkflowStore)

{:ok, cache} = ReadCache.start_link(sweep_interval_ms: 0)
{:ok, store} = ResourceStore.start_link([])
{:ok, broker} = BudgetBroker.start_link([])
assert :sys.get_state(store).path == Path.join(root, "github_resources.json")
key = {:issue, "o", "r", "42"}
assert :ok = ResourceStore.put_resource(key, %{"title" => "standalone"})
assert ResourceStore.data(key) == %{"title" => "standalone"}
assert :ok = ResourceStore.flush()
assert File.regular?(Path.join(root, "github_resources.json"))

request = %{method: :get, url: "https://api.github.com/repos/o/r/issues/42", token: "standalone-token", caller: "issue"}
assert {:ok, %{body: "cached"}} = ReadCache.through(request, fn -> {:ok, %{status: 200, body: "cached"}} end)
assert {:ok, %{body: "cached"}} = ReadCache.through(request, fn -> flunk("a standalone hit must not fetch") end)
assert {:ok, lease} = Budget.acquire(request)
assert File.regular?(Path.join(root, "github-budget/budget.sqlite3"))
assert Budget.release(lease) == :ok
refute File.exists?(Path.join(root, "wrong-domain-root"))
refute File.exists?(Path.join(root, "wrong-budget-root"))
refute Process.whereis(Aiur.WorkflowStore)
for pid <- [broker, store, cache], do: GenServer.stop(pid)
IO.puts("standalone GitHub access passed")
