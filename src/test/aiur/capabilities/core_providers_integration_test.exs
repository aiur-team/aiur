defmodule Aiur.Capabilities.CoreProvidersIntegrationTest do
  use Aiur.TestSupport

  alias Aiur.Capabilities.{Collector, Provider}
  alias Aiur.Executor.CapabilityProvider, as: Executor
  alias Aiur.Executor.{Claims, Roster}
  alias Aiur.Orchestrator.CapabilityProvider, as: Orchestration

  test "executor: roster read does not record an observation" do
    path = Path.join(Aiur.TestSupport.tmp_root!("core-provider-claims"), "claims.json")
    File.mkdir_p!(Path.dirname(path))
    now = DateTime.utc_now()
    assert {:ok, _claim} = Claims.claim("owner", path: path, now: now)
    Roster.build(path: path, now: now, cursor: 0, pending_count: 0)
    before = File.read!(path)
    assert %{executor: %{consumer_id: "owner", state: "idle"}} = Executor.executor(%{}, path: path, now: DateTime.add(now, 1, :second))
    assert File.read!(path) == before
  end

  test "production HTTP read distinguishes a bound listener from an endpoint without a server" do
    previous_config = Application.fetch_env!(:aiur, AiurWeb.Endpoint)
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.HttpServer)
    Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.put(previous_config, :server, false))

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, previous_config)
      Supervisor.restart_child(Aiur.Supervisor, Aiur.HttpServer)
    end)

    Aiur.TestSupport.start_owned_endpoint!()
    assert Provider.http(%{run_shape: %{http_listener: true}}) == %{state: :unavailable, reason: :not_running}
    spec = Supervisor.child_spec({Bandit, plug: AiurWeb.Endpoint, port: 0}, id: {AiurWeb.Endpoint, :http})
    assert {:ok, _server} = Supervisor.start_child(AiurWeb.Endpoint, spec)
    assert Provider.http(%{run_shape: %{http_listener: true}}) == %{state: :available}
  end

  test "registered providers report every core ID in no-dashboard shape and notice a dead orchestrator" do
    original = Application.get_env(:aiur, :no_dashboard)
    Application.put_env(:aiur, :no_dashboard, true)

    on_exit(fn ->
      if is_nil(original), do: Application.delete_env(:aiur, :no_dashboard), else: Application.put_env(:aiur, :no_dashboard, original)
    end)

    modules = Aiur.Application.child_specs(interactive_cli?: false, headless?: true, dashboard?: false, tailscale_funnel?: false)

    refute Enum.any?(modules, fn
             {Aiur.HttpServer, _} -> true
             _ -> false
           end)

    report = Aiur.Capabilities.report(table: :core_provider_report_missing)
    {_collected, warnings} = Collector.collect([])
    caps = report.capabilities
    assert caps["api.http"] == %{state: :unavailable, reason: :not_installed}
    assert caps["orchestration"].state in [:available, :degraded]
    assert caps["instance.status"].state in [:available, :degraded]
    assert caps["agents.run"] == %{state: :available}
    assert caps["executor.wakes"] == %{state: :unavailable, reason: :not_running}
    assert caps["executor.conversation"] == %{state: :unavailable, reason: :executor_not_managed}

    for id <- ~w(agents.message commands.read commands.answer) do
      assert caps[id] == %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["api.http"]}
    end

    for id <- ~w(commands.supervisor_api tracker.github tracker.linear), do: refute(Map.get(caps[id], :reason) == :not_installed)
    refute Enum.any?(warnings, &match?({:failed, _}, &1))
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, Aiur.Orchestrator) end)
    assert Process.whereis(Aiur.Orchestrator) == nil
    {after_stop, _warnings} = Collector.collect([])
    assert after_stop.capabilities["orchestration"] == %{state: :unavailable, reason: :not_running}
    assert Orchestration.capabilities(%{run_shape: %{http_listener: false}, settings: :unavailable})["agents.run"].state == :unavailable
  end
end
