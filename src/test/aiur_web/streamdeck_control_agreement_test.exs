defmodule AiurWeb.StreamdeckControlAgreementTest do
  @moduledoc """
  The Stream Deck command keys are only a control surface if the state they
  render is the state the rest of the system reports. These tests project one
  orchestrator `State` through all three operator-facing surfaces at once —
  the Stream Deck key, the dashboard Units row, and the `aiurdev status`
  report — and fail when any two of them disagree.
  """

  use Aiur.TestSupport

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{DispatchPolicy, PauseResume, PriorityControl, State, StatusReport}
  alias AiurWeb.OperatorControlCenter.{UnitsPolicy, UnitsPresenter}
  alias AiurWeb.StreamDeckGrid

  test "a running agent reads as running on the key, in Units, and in aiurdev status" do
    {key, unit, status} = three_sources(state_for([running_entry("1577", :working)]), "1577")

    assert key.bucket == :running
    assert UnitsPolicy.condition?(:active, unit)
    refute UnitsPolicy.condition?(:paused, unit)
    assert status.state == :running
    assert status.work_state == :working
  end

  test "pausing through the orchestrator reads as paused on the key, in Units, and in aiurdev status" do
    state = state_for([running_entry("1577", :working)])

    {key, unit, status} = three_sources(state, "1577")
    assert key.bucket == :running
    assert UnitsPolicy.condition?(:active, unit)
    assert status.state == :running

    paused_state = pause_through_orchestrator(state, "1577")

    {key, unit, status} = three_sources(paused_state, "1577")

    assert key.bucket == :paused
    assert UnitsPolicy.condition?(:paused, unit)
    refute UnitsPolicy.condition?(:active, unit)
    assert status.state == :paused
    assert status.work_state == :paused
  end

  test "resuming through the orchestrator returns every surface to running" do
    resumed_state =
      [running_entry("1577", :working)]
      |> state_for()
      |> pause_through_orchestrator("1577")
      |> resume_through_orchestrator("1577")

    {key, unit, status} = three_sources(resumed_state, "1577")

    assert key.bucket == :running
    assert UnitsPolicy.condition?(:active, unit)
    refute UnitsPolicy.condition?(:paused, unit)
    assert status.state == :running
    assert status.work_state == :working
  end

  test "prioritizing through the orchestrator moves the agent earlier and stars it on every surface" do
    state = state_for([running_entry("1500", :working), running_entry("1577", :working)])

    assert ["1500", "1577"] == deck_order(state)

    assert {:reply, {:ok, :prioritized}, prioritized_state} =
             PriorityControl.prioritize_agent_call(state, "1577",
               add_label_fun: fn _issue_id, _label -> :ok end,
               notify_dashboard_fun: fn _state -> :ok end
             )

    assert ["1577", "1500"] == deck_order(prioritized_state)

    {key, unit, status} = three_sources(prioritized_state, "1577")

    assert key.priority == true
    assert "priority:1" in status_labels(prioritized_state, "1577")
    # Priority must not disturb what the other two surfaces report about the agent.
    assert status.state == :running
    assert UnitsPolicy.condition?(:active, unit)

    assert ["1577", "1500"] ==
             prioritized_state.last_polled_issues
             |> Map.values()
             |> DispatchPolicy.sort_issues_for_dispatch()
             |> Enum.map(& &1.identifier)

    {other_key, _other_unit, _other_status} = three_sources(prioritized_state, "1500")

    assert other_key.priority == false
  end

  test "deprioritizing through the orchestrator drops the star and restores identifier ordering" do
    state = state_for([running_entry("1500", :working), running_entry("1577", :working, priority: 1, labels: ["priority:1"])])

    assert ["1577", "1500"] == deck_order(state)

    assert {:reply, {:ok, :deprioritized}, deprioritized_state} =
             PriorityControl.deprioritize_agent_call(state, "1577",
               remove_label_fun: fn _issue_id, _label -> :ok end,
               notify_dashboard_fun: fn _state -> :ok end
             )

    assert ["1500", "1577"] == deck_order(deprioritized_state)

    {key, unit, status} = three_sources(deprioritized_state, "1577")

    assert key.priority == false
    assert status.state == :running
    assert UnitsPolicy.condition?(:active, unit)
    refute "priority:1" in status_labels(deprioritized_state, "1577")
  end

  # Pause and resume settle in two steps in the real orchestrator: the control
  # call submits the request, and the worker's control-state report is what
  # actually flips the entry. Driving both here keeps this test honest — it
  # never writes `:paused` into the state the surfaces then read back.
  defp pause_through_orchestrator(%State{} = state, identifier) do
    assert {:reply, {:ok, request_id}, state} = PauseResume.pause_agent_call(state, identifier)
    assert is_integer(request_id)

    confirm_pending_control(state, identifier, :paused)
  end

  defp resume_through_orchestrator(%State{} = state, identifier) do
    assert {:reply, {:ok, request_id}, state} = PauseResume.request_control_call(state, identifier, :resume, 2)
    assert is_integer(request_id)

    confirm_pending_control(state, identifier, :working)
  end

  # The worker answers a control request with its own generation; replaying the
  # pending request's real generation is what makes the orchestrator treat this
  # as evidence for that request rather than an unrelated status report.
  defp confirm_pending_control(%State{} = state, issue_id, status) do
    request_id = state.control_lifecycle.pending[issue_id]
    request = state.control_lifecycle.records[request_id]

    assert {:noreply, state} =
             PauseResume.handle_worker_control_state(state, issue_id, status, %{
               request_id: request_id,
               generation: request.generation
             })

    state
  end

  defp three_sources(%State{} = state, identifier) do
    snapshot = StatusReport.snapshot_payload(state)

    key =
      snapshot
      |> StreamDeckGrid.project()
      |> Map.fetch!(:agents)
      |> Enum.find(&(to_string(&1.identifier) == identifier))

    unit =
      snapshot
      |> units_catalog()
      |> Map.fetch!(:snapshot)
      |> Map.fetch!(:rows)
      |> Enum.find(&(&1.identity.identifier == identifier))

    status =
      state
      |> StatusReport.agent_statuses(fn _timeout -> {:unavailable, nil} end)
      |> Enum.find(&(to_string(&1.identifier) == identifier))

    refute is_nil(key), "no Stream Deck key for ##{identifier}"
    refute is_nil(unit), "no Units row for ##{identifier}"
    refute is_nil(status), "no aiurdev status entry for ##{identifier}"

    {key, unit, status}
  end

  defp deck_order(%State{} = state) do
    state
    |> StatusReport.snapshot_payload()
    |> StreamDeckGrid.project()
    |> Map.fetch!(:agents)
    |> Enum.map(&to_string(&1.identifier))
  end

  defp units_catalog(snapshot) do
    identities = Enum.map(snapshot.running, & &1.tracker_identity)

    UnitsPresenter.load(
      %{generated_at: "2026-08-09T12:00:00Z", provider_health: %{fleet: :ok, decisions: :ok}, fleet: snapshot, decisions: []},
      membership_fun: fn -> membership(identities) end,
      activity_fun: fn -> %{generation: 1, entries: []} end
    )
  end

  defp status_labels(%State{} = state, identifier) do
    state.last_polled_issues
    |> Map.values()
    |> Enum.find(&(&1.identifier == identifier))
    |> Map.fetch!(:labels)
  end

  defp state_for(entries) do
    %State{
      running: Map.new(entries, fn entry -> {entry.issue.id, entry} end),
      last_polled_issues: Map.new(entries, fn entry -> {entry.issue.id, entry.issue} end),
      retry_attempts: %{}
    }
  end

  defp running_entry(identifier, work_state, opts \\ []) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{
        id: identifier,
        identifier: identifier,
        state: "In Progress",
        title: "Stream Deck #{identifier}",
        url: "https://example.test/issues/#{identifier}",
        labels: Keyword.get(opts, :labels, []),
        priority: Keyword.get(opts, :priority),
        tracker_identity: tracker_identity(identifier)
      },
      control: %{
        can_interrupt: true,
        safe_checkpoints: [:notification],
        status: work_state,
        application_confirmation: :confirmed,
        generation: 101,
        version: 0
      },
      session_id: "thread-#{identifier}",
      started_at: DateTime.utc_now(),
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0
    }
  end

  defp membership(identities) do
    %{
      generation: 1,
      health: :healthy,
      health_message: "current-run membership is healthy",
      freshness: %{status: :fresh},
      truncated?: false,
      members:
        Enum.map(identities, fn identity ->
          %{
            identity: identity,
            lifecycle: :running,
            terminal?: false,
            first_observed_at: ~U[2026-08-09 11:00:00Z],
            last_observed_at: ~U[2026-08-09 12:00:00Z]
          }
        end)
    }
  end

  defp tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "aiur-team",
      repository: "aiur",
      provider_id: "I_kwDO#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end
end
