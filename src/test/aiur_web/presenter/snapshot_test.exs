defmodule AiurWeb.PresenterSnapshotTest do
  use Aiur.TestSupport

  alias Aiur.Events.SubscriptionStore
  alias Aiur.{Issue, TicketActivity, TicketObservation}
  alias Aiur.Orchestrator
  alias Aiur.TicketActivity.Projection
  alias AiurWeb.Presenter

  import AiurWeb.PresenterFixtures

  test "snapshot carries fresh activity progress, including retained retry identities" do
    original_activity_state = :sys.get_state(TicketActivity)
    orchestrator_name = Module.concat(__MODULE__, :ActivityProgressOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    now = DateTime.utc_now()
    running_identity = tracker_identity("1001")
    retry_identity = tracker_identity("1002")
    idle_identity = tracker_identity("1003")

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      :sys.replace_state(TicketActivity, fn _state -> original_activity_state end)
    end)

    activity_projection =
      [{running_identity, 60}, {retry_identity, 40}, {idle_identity, 20}]
      |> Enum.with_index(1)
      |> Enum.reduce(Projection.new(), fn {{identity, percent}, event_id}, projection ->
        observation = %TicketObservation{
          status: :joinable,
          reason: nil,
          tracker_identity: identity,
          source: %{kind: :agent_event, name: "progress"},
          event_id: event_id,
          provenance: %{run_id: "run-activity", attempt: 1},
          occurred_at: now,
          observed_at: now,
          attributes: %{percent: percent}
        }

        {:accepted, projection} = Projection.apply(projection, observation)
        projection
      end)

    :sys.replace_state(TicketActivity, fn state -> %{state | projection: activity_projection} end)

    entry =
      "issue-activity"
      |> running_entry("1001", :working)
      |> put_in([:issue, Access.key(:tracker_identity)], running_identity)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-activity" => entry},
          retry_attempts: %{
            "issue-retry" => %{
              attempt: 1,
              timer_ref: nil,
              due_at_ms: System.monotonic_time(:millisecond) + 5_000,
              identifier: "1002",
              tracker_identity: retry_identity,
              priority: 1
            }
          },
          last_polled_issues: %{
            "issue-idle" => %Issue{id: "issue-idle", identifier: "1003", state: "todo", tracker_identity: idle_identity}
          }
      }
    end)

    assert %{
             running: [%{progress_percent: 60}],
             retrying: [%{progress_percent: 40, priority: 1}],
             idle: [%{progress_percent: 20}]
           } = Orchestrator.snapshot(orchestrator_name, 1_000)
  end

  test "snapshot stays available when the activity projection is unresponsive" do
    orchestrator_name = Module.concat(__MODULE__, :UnavailableActivityOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      :sys.resume(TicketActivity)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.suspend(TicketActivity)

    assert %{running: [], retrying: [], idle: []} = Orchestrator.snapshot(orchestrator_name, 1_000)
  end

  test "snapshot retains stale activity progress and marks it stale" do
    original_activity_state = :sys.get_state(TicketActivity)
    orchestrator_name = Module.concat(__MODULE__, :StaleActivityOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    identity = tracker_identity("1004")
    observed_at = DateTime.add(DateTime.utc_now(), -2, :second)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      :sys.replace_state(TicketActivity, fn _state -> original_activity_state end)
    end)

    observation = %TicketObservation{
      status: :joinable,
      reason: nil,
      tracker_identity: identity,
      source: %{kind: :agent_event, name: "progress"},
      event_id: 1,
      provenance: %{run_id: "run-activity", attempt: 1},
      occurred_at: observed_at,
      observed_at: observed_at,
      attributes: %{percent: 60}
    }

    {:accepted, projection} = Projection.new(stale_after_ms: 1) |> Projection.apply(observation)
    :sys.replace_state(TicketActivity, fn state -> %{state | projection: projection} end)

    entry =
      "issue-stale-activity"
      |> running_entry("1004", :working)
      |> put_in([:issue, Access.key(:tracker_identity)], identity)

    :sys.replace_state(pid, fn state -> %{state | running: %{"issue-stale-activity" => entry}} end)

    # A reading that aged out of the staleness window is still the last thing
    # anyone measured. Replacing it with 0 was what made the Stream Deck flicker
    # 0 -> 60 -> 0 on a ticket that never stopped progressing.
    assert %{running: [%{progress_percent: 60, progress_freshness: :stale}]} = Orchestrator.snapshot(orchestrator_name, 1_000)
  end

  test "surfaces the global pause switch and a run_paused row for a globally held agent" do
    orchestrator_name = Module.concat(__MODULE__, :GlobalPauseOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    held_entry =
      "issue-held"
      |> running_entry("MT-950", :paused)
      |> Map.put(:paused_reason, :global_pause)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-held" => held_entry}, globally_paused: true, global_pause: %{paused_at: ~U[2026-08-01 12:00:00Z], source: "dashboard"}}
    end)

    publish_dashboard_snapshot(pid)

    payload = Presenter.state_payload(orchestrator_name, 1_000)

    assert payload.globally_paused == true
    # Provenance is not exposed: the nav toggle only needs the boolean, and no
    # surface renders `paused_at` / `source` since the pause banner was removed.
    refute Map.has_key?(payload, :global_pause)
    assert [running_row] = payload.running
    assert running_row.waiting_reason == :run_paused
  end

  test "open decision count is available without an attached SubscriptionStore" do
    orchestrator_name = Module.concat(__MODULE__, :UnavailableDecisionCountOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    identifier = "MT-unavailable-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      SubscriptionStore.stop(identifier)
    end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-decision" => running_entry("issue-decision", identifier, :working)}}
    end)

    publish_dashboard_snapshot(pid)

    payload = Presenter.state_payload(orchestrator_name, 1_000)

    assert [running_row] = payload.running
    assert running_row.open_decision_count == 0
    assert running_row.open_decision_count_health == :available
  end
end
