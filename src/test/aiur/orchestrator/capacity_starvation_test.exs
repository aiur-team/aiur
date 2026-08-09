defmodule Aiur.Orchestrator.CapacityStarvationTest do
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

  test "emits fleet.capacity.starved after three sustained under-utilized polls" do
    state = state_with_live_agents(3, effective_cap: 20)
    issues = Enum.map(1..8, &issue("ready-#{&1}"))
    alert_fun = alert_fun(self())

    state = observe(state, issues, alert_fun)
    state = observe(state, issues, alert_fun)
    refute_receive {:alert, _, _}

    state = observe(state, issues, alert_fun)

    assert_receive {:alert, "fleet.capacity.starved", opts}
    assert opts[:needs_attention]
    assert opts[:severity] == "warning"
    assert opts[:reason] =~ "8 ready, 3 live"
    assert opts[:reason] =~ "load 0.7 on 16 schedulers"
    assert opts[:reason] =~ "cap 20"
    assert opts[:reason] =~ "no binding constraint identified"

    assert opts[:details] == %{
             "authorization_denials" => 0,
             "binding_constraint" => "none",
             "configured_cap" => 20,
             "debounce_cycles" => 3,
             "effective_cap" => 20,
             "live_agents" => 3,
             "load_average" => 0.7,
             "ready_count" => 8,
             "schedulers" => 16,
             "target_load" => 16.0
           }

    _state = observe(state, issues, alert_fun)
    refute_receive {:alert, _, _}
  end

  test "does not emit while the fleet or adaptive envelope is ramping" do
    issues = Enum.map(1..8, &issue("ready-#{&1}"))
    alert_fun = alert_fun(self())

    state = state_with_live_agents(1, effective_cap: 1)
    state = observe(state, issues, alert_fun)

    state = %{state_with_live_agents(2, effective_cap: 2) | capacity_starvation: state.capacity_starvation}
    state = observe(state, issues, alert_fun)

    state = %{state_with_live_agents(3, effective_cap: 3) | capacity_starvation: state.capacity_starvation}
    state = observe(state, issues, alert_fun)

    state = %{state_with_live_agents(4, effective_cap: 4) | capacity_starvation: state.capacity_starvation}
    _state = observe(state, issues, alert_fun)

    refute_receive {:alert, _, _}
  end

  test "clears a recovered incident and rearms for later starvation" do
    state = state_with_live_agents(3, effective_cap: 20)
    issues = Enum.map(1..8, &issue("ready-#{&1}"))
    alert_fun = alert_fun(self())

    state = observe(state, issues, alert_fun)
    state = observe(state, issues, alert_fun)
    state = observe(state, issues, alert_fun)
    assert_receive {:alert, "fleet.capacity.starved", _opts}

    state = observe(state, [], alert_fun)
    assert_receive {:alert, "fleet.capacity.starved.resolved", opts}
    refute opts[:needs_attention]

    state = observe(state, issues, alert_fun)
    state = observe(state, issues, alert_fun)
    _state = observe(state, issues, alert_fun)

    assert_receive {:alert, "fleet.capacity.starved", _opts}
  end

  test "retries an incident when required alert persistence fails" do
    state = state_with_live_agents(3, effective_cap: 20)
    issues = Enum.map(1..8, &issue("ready-#{&1}"))
    attempt_key = {__MODULE__, make_ref()}

    alert_fun = fn name, opts ->
      attempt = Process.get(attempt_key, 0) + 1
      Process.put(attempt_key, attempt)
      send(self(), {:alert_attempt, attempt, name, opts})
      if attempt == 1, do: {:error, :eacces}, else: :ok
    end

    state = observe(state, issues, alert_fun)
    state = observe(state, issues, alert_fun)
    state = observe(state, issues, alert_fun)

    assert_receive {:alert_attempt, 1, "fleet.capacity.starved", _opts}
    refute state.capacity_starvation.alert_active?

    state = observe(state, issues, alert_fun)
    assert_receive {:alert_attempt, 2, "fleet.capacity.starved", _opts}
    assert state.capacity_starvation.alert_active?
  end

  test "does not overlap the zero-live fleet halt condition" do
    issues = Enum.map(1..8, &issue("ready-#{&1}"))
    alert_fun = alert_fun(self())

    state = %State{max_concurrent_agents: 20, effective_concurrent_agents: 20}

    state = observe(state, issues, alert_fun)
    state = observe(state, issues, alert_fun)
    _state = observe(state, issues, alert_fun)

    refute_receive {:alert, _, _}
  end

  defp observe(state, issues, alert_fun, sample_overrides \\ %{}) do
    CapacityStarvation.observe(
      state,
      issues,
      Map.merge(
        %{
          load: 0.7,
          target: 1.0,
          schedulers: 16,
          prewarm_hold?: false,
          admission_constraint: nil
        },
        sample_overrides
      ),
      alert_fun: alert_fun
    )
  end

  defp alert_fun(test_pid) do
    fn name, opts ->
      send(test_pid, {:alert, name, opts})
      :ok
    end
  end

  defp state_with_live_agents(count, opts) do
    running =
      Map.new(1..count, fn index ->
        id = "running-#{index}"

        {id,
         %{
           issue: issue(id, state: "in-progress"),
           control: %{status: :working}
         }}
      end)

    %State{
      max_concurrent_agents: 20,
      effective_concurrent_agents: Keyword.fetch!(opts, :effective_cap),
      running: running
    }
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
