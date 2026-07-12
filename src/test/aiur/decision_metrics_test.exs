defmodule Aiur.DecisionMetricsTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionMetrics, DecisionStore, OperatorWaitLog}
  alias Aiur.Events.Exchange

  @moduletag :tmp_dir
  @requested_at ~U[2026-07-12 12:00:00.000Z]
  @observed_at ~U[2026-07-12 12:00:10.000Z]

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "decision_latency.ndjson")
    pid = start_metrics!(path)
    on_exit(fn -> stop_if_alive(pid) end)
    %{path: path, pid: pid}
  end

  test "records every requested-to-acknowledged interval from lifecycle facts", %{pid: pid, path: path} do
    assert :ok = DecisionMetrics.observe(request_event(1, true), pid)

    assert :ok =
             DecisionMetrics.observe(
               lifecycle_event(2, "answered", 2_000, %{actor: %{type: :human}}),
               pid
             )

    assert :ok =
             DecisionMetrics.observe(
               lifecycle_event(3, "lifecycle", 2_500, %{event_type: "dispatch.queued"}),
               pid
             )

    assert :ok = DecisionMetrics.observe(lifecycle_event(4, "delivered", 4_000), pid)
    assert :ok = DecisionMetrics.observe(lifecycle_event(5, "acknowledged", 5_000), pid)

    assert {:ok, snapshot} = DecisionMetrics.snapshot("dec-42", pid)
    assert snapshot.request_to_decision_ms == 2_000
    assert snapshot.decision_to_dispatch_ms == 500
    assert snapshot.dispatch_to_delivery_ms == 1_500
    assert snapshot.delivery_to_ack_ms == 1_000
    assert snapshot.blocked_time_ms == 5_000
    assert snapshot.actor == "human"
    refute snapshot.revised

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 5

    last = lines |> List.last() |> Jason.decode!()
    assert last["stage"] == "acknowledged"
    assert last["delivery_to_ack_ms"] == 1_000
  end

  test "keeps incomplete and out-of-order durations explicit", %{pid: pid} do
    assert :ok = DecisionMetrics.observe(request_event(10, false), pid)
    assert :ok = DecisionMetrics.observe(lifecycle_event(11, "delivered", 1_000), pid)
    assert :ok = DecisionMetrics.observe(lifecycle_event(12, "dispatched", 2_000), pid)

    assert {:ok, snapshot} = DecisionMetrics.snapshot("dec-42", pid)
    assert snapshot.request_to_decision_ms == nil
    assert snapshot.decision_to_dispatch_ms == nil
    assert snapshot.dispatch_to_delivery_ms == nil
    assert snapshot.delivery_to_ack_ms == nil
    assert snapshot.blocked_time_ms == 0
  end

  test "deduplicates reminders and records actor plus revision without content", %{pid: pid, path: path} do
    assert :ok = DecisionMetrics.observe(request_event(20, true), pid)

    assert :ok =
             DecisionMetrics.observe(
               lifecycle_event(21, "answered", 1_000, %{actor: %{"type" => "supervising_agent"}}),
               pid
             )

    first_attention = attention_event(22, 2_000)
    assert :ok = DecisionMetrics.observe(first_attention, pid)
    assert :ok = DecisionMetrics.observe(attention_event(23, 3_000), pid)
    assert :duplicate = DecisionMetrics.observe(first_attention, pid)
    assert :ok = DecisionMetrics.observe(lifecycle_event(24, "reminded", 4_000), pid)
    assert :ok = DecisionMetrics.observe(lifecycle_event(25, "revised", 5_000, %{actor: "human"}), pid)

    assert {:ok, snapshot} = DecisionMetrics.snapshot("dec-42", pid)
    assert snapshot.attention_count == 2
    assert snapshot.reminder_count == 2
    assert snapshot.actor == "supervisor"
    assert snapshot.revised

    persisted = File.read!(path)
    refute persisted =~ "the exact question"
    refute persisted =~ "the operator answer"
    refute persisted =~ "private rationale"
  end

  test "replays snapshots and observed event IDs across restarts", %{pid: pid, path: path} do
    event = request_event(30, true)
    assert :ok = DecisionMetrics.observe(event, pid)
    assert :ok = DecisionMetrics.observe(lifecycle_event(31, "answered", 750, %{actor_type: "operator"}), pid)
    GenServer.stop(pid)
    File.write!(path, "not-json\n", [:append])

    replayed = start_metrics!(path)
    on_exit(fn -> stop_if_alive(replayed) end)

    assert {:ok, snapshot} = DecisionMetrics.snapshot("dec-42", replayed)
    assert snapshot.request_to_decision_ms == 750
    assert snapshot.actor == "human"

    before = path |> File.read!() |> String.split("\n", trim: true) |> length()
    assert :duplicate = DecisionMetrics.observe(event, replayed)
    after_replay = path |> File.read!() |> String.split("\n", trim: true) |> length()
    assert after_replay == before
  end

  test "subscribes to the existing Exchange and ignores unrelated decision coordination", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "exchange-decision-latency.ndjson")
    pid = start_metrics!(path, subscribe?: true)
    on_exit(fn -> stop_if_alive(pid) end)

    assert Exchange.publish("ticket.42.agent.decision.requested", request_event(40, true)) >= 1
    assert {:ok, snapshot} = DecisionMetrics.snapshot("dec-42", pid)
    assert snapshot.requested_at == DateTime.to_iso8601(@requested_at)

    unrelated = %{id: 41, topic: "ticket.42.agent.decision.use-amqp", decision_id: "dec-other"}
    assert Exchange.publish(unrelated.topic, unrelated) >= 1
    assert {:error, :not_found} = DecisionMetrics.snapshot("dec-other", pid)
  end

  test "observes a real DecisionStore request only after its canonical append", %{tmp_dir: tmp_dir} do
    metrics_path = Path.join(tmp_dir, "store-decision-latency.ndjson")
    state_dir = Path.join(tmp_dir, "decision-state")
    metrics = start_metrics!(metrics_path, subscribe?: true)
    previous_state_dir = Application.get_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, state_dir)

    on_exit(fn ->
      stop_if_alive(metrics)

      if previous_state_dir,
        do: Application.put_env(:aiur, :decision_state_dir, previous_state_dir),
        else: Application.delete_env(:aiur, :decision_state_dir)
    end)

    {:ok, store} = DecisionStore.start_link(name: nil, filesystem_sync_fun: fn -> :ok end)
    on_exit(fn -> stop_if_alive(store) end)

    ticket = %{identifier: "42", title: "Decision metrics", url: nil}
    source = %{agent_id: "agent-42", session_id: "session-42", event_id: nil}

    assert {:ok, %{status: :accepted, decision: decision}} =
             DecisionStore.request(
               %{"question" => "Ship this?", "blocking" => true, "source_id" => "metrics-integration"},
               [ticket: ticket, source: source],
               store
             )

    assert File.read!(Path.join(state_dir, "decisions.ndjson")) =~ decision.decision_id
    assert {:ok, snapshot} = DecisionMetrics.snapshot(decision.decision_id, metrics)
    assert snapshot.requested_at == DateTime.to_iso8601(decision.created_at)
  end

  test "metrics_file/0 follows the existing configurable metrics-path convention", %{path: path} do
    previous = Application.get_env(:aiur, :decision_metrics_path)
    Application.put_env(:aiur, :decision_metrics_path, path)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :decision_metrics_path, previous), else: Application.delete_env(:aiur, :decision_metrics_path)
    end)

    assert DecisionMetrics.metrics_file() == path
  end

  test "decision and operator-wait streams share the active metrics directory", %{tmp_dir: tmp_dir} do
    previous_log_file = Application.get_env(:aiur, :log_file)
    previous_decision_path = Application.get_env(:aiur, :decision_metrics_path)
    previous_wait_path = Application.get_env(:aiur, :operator_wait_metrics_path)
    Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))
    Application.delete_env(:aiur, :decision_metrics_path)
    Application.delete_env(:aiur, :operator_wait_metrics_path)

    on_exit(fn ->
      restore_env(:log_file, previous_log_file)
      restore_env(:decision_metrics_path, previous_decision_path)
      restore_env(:operator_wait_metrics_path, previous_wait_path)
    end)

    metrics_dir = Path.join(tmp_dir, "metrics")
    assert DecisionMetrics.metrics_file() == Path.join(metrics_dir, "decision_latency.ndjson")
    assert OperatorWaitLog.metrics_file() == Path.join(metrics_dir, "operator_message_wait.ndjson")
  end

  defp start_metrics!(path, opts \\ []) do
    {:ok, pid} =
      DecisionMetrics.start_link(Keyword.merge([name: nil, path: path, subscribe?: false, clock: fn -> @observed_at end], opts))

    pid
  end

  defp request_event(id, blocking) do
    %{
      id: id,
      topic: "ticket.42.agent.decision.requested",
      decision_id: "dec-42",
      ticket: %{identifier: "42"},
      blocking: blocking,
      created_at: DateTime.to_iso8601(@requested_at),
      question: "the exact question"
    }
  end

  defp lifecycle_event(id, suffix, offset_ms, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        topic: "ticket.42.agent.decision.#{suffix}",
        decision_id: "dec-42",
        at: @requested_at |> DateTime.add(offset_ms, :millisecond) |> DateTime.to_iso8601(),
        answer: "the operator answer",
        rationale: "private rationale"
      },
      extra
    )
  end

  defp attention_event(id, offset_ms) do
    lifecycle_event(id, "ignored", offset_ms)
    |> Map.put(:topic, "ticket.42.agent.attention.operator-decision")
    |> Map.put(:type, "alert")
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
