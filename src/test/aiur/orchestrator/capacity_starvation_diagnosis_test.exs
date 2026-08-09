defmodule Aiur.Orchestrator.CapacityStarvationDiagnosisTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.CapacityStarvation
  alias Aiur.Orchestrator.State

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 20,
      target_load_average: 1.0
    )

    :ok
  end

  test "names dispatch authorization denials when they bind all ready work" do
    issues = Enum.map(1..8, &issue("denied-#{&1}", dispatch_authorized?: false))
    opts = emit_and_receive(state_with_live_agents(20), issues)

    assert opts[:reason] =~ "binding constraint: dispatch authorization denials (8)"
    assert opts[:details]["binding_constraint"] == "dispatch_authorization_denials"
    assert opts[:details]["authorization_denials"] == 8
  end

  test "names a sustained prewarm hold" do
    issues = Enum.map(1..8, &issue("ready-#{&1}"))
    opts = emit_and_receive(state_with_live_agents(20), issues, %{prewarm_hold?: true})

    assert opts[:reason] =~ "binding constraint: prewarm hold"
    assert opts[:details]["binding_constraint"] == "prewarm_hold"
  end

  test "names an effective envelope that stays binding for the debounce window" do
    issues = Enum.map(1..8, &issue("ready-#{&1}"))
    state = state_with_live_agents(3)
    opts = emit_and_receive(state, issues, %{}, 4)

    assert opts[:reason] =~ "binding constraint: effective envelope (cap 3 static)"
    assert opts[:details]["binding_constraint"] == "effective_envelope"
  end

  test "names provisioning rate when capacity rises without live-agent growth" do
    issues = Enum.map(1..8, &issue("ready-#{&1}"))
    alert_fun = alert_fun(self())

    state = observe(state_with_live_agents(4), issues, alert_fun)
    state = observe(%{state | effective_concurrent_agents: 5}, issues, alert_fun)
    _state = observe(%{state | effective_concurrent_agents: 6}, issues, alert_fun)

    assert_receive {:alert, "fleet.capacity.starved", opts}
    assert opts[:reason] =~ "binding constraint: provisioning rate"
    assert opts[:details]["binding_constraint"] == "provisioning_rate"
  end

  defp emit_and_receive(state, issues, overrides \\ %{}, cycles \\ 3) do
    alert_fun = alert_fun(self())

    Enum.reduce(1..cycles, state, fn _, next_state ->
      observe(next_state, issues, alert_fun, overrides)
    end)

    assert_receive {:alert, "fleet.capacity.starved", opts}
    opts
  end

  defp observe(state, issues, alert_fun, sample_overrides \\ %{}) do
    sample =
      Map.merge(
        %{load: 0.7, target: 1.0, schedulers: 16, prewarm_hold?: false, admission_constraint: nil},
        sample_overrides
      )

    CapacityStarvation.observe(state, issues, sample, alert_fun: alert_fun)
  end

  defp alert_fun(test_pid) do
    fn name, opts ->
      send(test_pid, {:alert, name, opts})
      :ok
    end
  end

  defp state_with_live_agents(effective_cap) do
    running =
      Map.new(1..3, fn index ->
        id = "running-#{index}"
        {id, %{issue: issue(id, state: "in-progress"), control: %{status: :working}}}
      end)

    %State{max_concurrent_agents: 20, effective_concurrent_agents: effective_cap, running: running}
  end

  defp issue(id, opts \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: id,
          identifier: id,
          title: "Issue #{id}",
          state: "todo",
          dispatch_authorized?: true,
          assigned_to_worker: true,
          blocked_by: []
        ],
        opts
      )
    )
  end
end
