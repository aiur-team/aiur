defmodule Aiur.DecisionProjectionRecoveryTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.{AgentControlCLI, DecisionQuery, DecisionStore, JsonStore}
  alias Aiur.DecisionStore.ProjectionRecovery
  alias Aiur.Events.Exchange

  @moduletag :tmp_dir
  @ticket %{identifier: "3275", title: "Projection recovery", url: "https://github.com/aiur-team/aiur/issues/3275"}

  defp start_store(dir, opts \\ []) do
    parent = self()

    publisher = fn decision ->
      send(parent, {:notified, decision.decision_id})
      {:ok, 1, 0}
    end

    defaults = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      executor_request_publisher: publisher,
      executor_request_boot_reconciler: fn _ -> {:ok, 0} end,
      dispatcher: fn _, _ ->
        send(parent, :dispatched)
        {:error, :test_disabled}
      end,
      reconcile_delay_ms: 60_000,
      dispatch_delay_ms: 60_000
    ]

    {:ok, pid} = DecisionStore.start_link(Keyword.merge(defaults, opts))
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp request(pid, source) do
    DecisionStore.request(
      %{"question" => "Deploy?", "blocking" => true, "source_id" => source, "options" => [%{"id" => "ship", "label" => "Ship"}]},
      [ticket: @ticket, source: %{agent_id: "agent-3275", session_id: "session-3275", event_id: nil}],
      pid
    )
  end

  defp break_projection(dir) do
    path = Path.join(dir, "decisions.json")
    bytes = File.read!(path)
    File.rm!(path)
    File.mkdir!(path)
    {path, bytes}
  end

  defp restore_projection({path, bytes}) do
    File.rmdir!(path)
    File.write!(path, bytes)
  end

  test "accepted append remains queryable and writable, stale alert occurs once", %{tmp_dir: dir} do
    pid = start_store(dir)
    broken = break_projection(dir)

    log =
      capture_log(fn ->
        assert {:ok, %{decision: first}} = request(pid, "first")
        assert {:projection_stale, %DateTime{} = since} = DecisionStore.health(pid)
        assert {:ok, %{decision: ^first, health: {:projection_stale, ^since}}} = DecisionStore.retained_lookup(first.decision_id, pid)
        assert {:ok, %{health: %{stale: true, label: label}}} = DecisionQuery.get(first.decision_id, store: pid)
        assert label =~ "age "
        assert {:ok, %{status: :accepted}} = request(pid, "second")
        send(pid, :repair_decision_projection)
        assert DecisionStore.health(pid) == {:projection_stale, since}
        refute_received {:notified, _}
      end)

    assert length(Regex.scan(~r/phase=projection_repair_failed/, log)) == 1
    restore_projection(broken)
  end

  test "request, enrichment and lifecycle notifications wait for repair and drain once in journal order", %{tmp_dir: dir} do
    pid = start_store(dir)
    assert {:ok, %{decision: decision}} = request(pid, "before-failure")
    assert_received {:notified, id}
    assert id == decision.decision_id
    :ok = Exchange.subscribe("ticket.3275.agent.decision.*")
    broken = break_projection(dir)
    assert {:ok, %{decision: second}} = request(pid, "withheld-request")

    assert {:ok, %{status: :accepted}} =
             DecisionStore.enrich(decision.decision_id, %{"context" => %{"short_summary" => "Updated"}}, [actor: %{kind: :supervisor, id: "supervising-agent"}, expected_version: 1], pid)

    assert {:ok, %{status: :accepted}} = DecisionStore.defer(decision.decision_id, [actor: %{kind: :operator, id: "operator"}], pid)
    refute_received {:notified, _}
    refute_received {:event, _}
    restore_projection(broken)
    send(pid, :repair_decision_projection)
    assert DecisionStore.health(pid) == :writable
    assert_received {:notified, second_id}
    assert second_id == second.decision_id
    events = for _ <- 1..3, do: elem(receive_barrier({:event, _event}), 1)
    assert Enum.map(events, & &1.topic) == ["ticket.3275.agent.decision.requested", "ticket.3275.agent.decision.enriched", "ticket.3275.agent.decision.deferred"]
    assert {:ok, projection} = JsonStore.read(Path.join(dir, "decisions.json"))
    [requested, enriched, deferred] = events
    [_initial, request_record, enrichment_record, deferred_record] = File.read!(Path.join(dir, "decisions.ndjson")) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert request_record["event_id"] == "decision-provenance-v1:#{requested.id}"
    assert enrichment_record["event_id"] == "decision-provenance-v1:#{enriched.id}"
    assert deferred_record["event_id"] == deferred.id
    assert projection["pending_notification_ids"] == []
    assert projection["last_event_id"] == List.last(events).id
    send(pid, :repair_decision_projection)
    assert DecisionStore.health(pid) == :writable
    refute_received {:notified, _}
    refute_received {:event, _}
  end

  test "an answer held by stale projection dispatches after repair", %{tmp_dir: dir} do
    parent = self()
    scheduler = fn pid, message, _delay -> send(parent, {:scheduled, pid, message}) end
    pid = start_store(dir, dispatch_scheduler: scheduler)
    receive_barrier({:scheduled, ^pid, {:reconcile_dispatches, []}})
    assert {:ok, %{decision: decision}} = request(pid, "held-answer")
    broken = break_projection(dir)

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(decision.decision_id, %{"idempotency_key" => "held-answer", "expected_version" => 1, "option_id" => "ship"}, [actor: %{kind: :operator, id: "operator"}], pid)

    refute_received {:scheduled, ^pid, {:dispatch_action, _, _}}
    restore_projection(broken)
    send(pid, :repair_decision_projection)
    receive_barrier({:scheduled, ^pid, {:reconcile_dispatches, [_ | _]} = reconcile})
    send(pid, reconcile)
    receive_barrier({:scheduled, ^pid, {:dispatch_action, _, _} = dispatch})
    send(pid, dispatch)
    receive_barrier(:dispatched)
  end

  test "withheld notification replays once after restart, then stays cleared on another restart", %{tmp_dir: dir} do
    pid = start_store(dir)
    broken = break_projection(dir)
    assert {:ok, %{decision: decision}} = request(pid, "withheld")
    refute_received {:notified, _}
    GenServer.stop(pid)
    restore_projection(broken)
    restarted = start_store(dir)
    assert DecisionStore.health(restarted) == :writable
    assert_received {:notified, id}
    assert id == decision.decision_id
    GenServer.stop(restarted)
    again = start_store(dir)
    assert DecisionStore.health(again) == :writable
    refute_received {:notified, _}
  end

  test "crash after projection write before notification retains pending event ID", %{tmp_dir: dir} do
    parent = self()

    publisher = fn decision ->
      send(parent, {:notification_started, decision.decision_id})

      receive do
        :release -> {:ok, 1, 0}
      end
    end

    pid = start_store(dir, executor_request_publisher: publisher)
    monitor = Process.monitor(pid)

    spawn(fn ->
      try do
        request(pid, "crash-window")
      catch
        :exit, _ -> :ok
      end
    end)

    receive_barrier({:notification_started, id})
    assert {:ok, projection} = JsonStore.read(Path.join(dir, "decisions.json"))
    assert [event_id] = projection["pending_notification_ids"]
    assert event_id == projection["last_event_id"]
    Process.exit(pid, :kill)
    receive_barrier({:DOWN, ^monitor, :process, ^pid, :killed})
    restarted = start_store(dir)
    assert DecisionStore.health(restarted) == :writable
    assert_received {:notified, ^id}
    GenServer.stop(restarted)
    again = start_store(dir)
    assert DecisionStore.health(again) == :writable
    refute_received {:notified, _}
  end

  test "stale status renders timestamp and age, unknown timestamp renders age unknown", %{tmp_dir: dir} do
    original = Process.whereis(DecisionStore)
    if original, do: Process.unregister(DecisionStore)
    pid = start_store(dir, name: DecisionStore)

    on_exit(fn ->
      if Process.whereis(DecisionStore) == pid, do: Process.unregister(DecisionStore)
      if original && Process.alive?(original), do: Process.register(original, DecisionStore)
    end)

    broken = break_projection(dir)
    assert {:ok, _} = request(pid, "status")
    assert {:projection_stale, since} = DecisionStore.health(pid)
    output = capture_io(fn -> AgentControlCLI.status(fleet_view: {:ok, %{statuses: []}, %{status: :current, reason: nil, age_seconds: 0}}, global_paused: false) end)
    assert output =~ DateTime.to_iso8601(since)
    assert output =~ ~r/\(age \d+s\)/
    assert ProjectionRecovery.label({:projection_stale, nil}) =~ "age unknown"
    restore_projection(broken)
  end
end
