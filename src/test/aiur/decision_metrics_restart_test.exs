defmodule Aiur.DecisionMetricsRestartTest do
  use ExUnit.Case, async: false

  alias Aiur.DecisionMetrics
  alias Aiur.DecisionMetrics.Log
  alias Aiur.DecisionStore
  alias Aiur.Events.Exchange
  alias Aiur.OperatorWaitLog

  @moduletag :tmp_dir
  @requested_at ~U[2026-07-12 12:00:00.000Z]
  @observed_at ~U[2026-07-12 12:00:10.000Z]

  test "replays snapshots and observed event IDs across restarts", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "decision-latency.ndjson")
    metrics = start_metrics!(path)
    event = request_event(30)
    assert :ok = DecisionMetrics.observe(event, metrics)
    assert :ok = DecisionMetrics.observe(lifecycle_event(31, "answered", 750, %{actor_type: "operator"}), metrics)
    GenServer.stop(metrics)
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

  test "subscribes before replay so restart-time events queue in the mailbox", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "subscribe-before-replay.ndjson")
    parent = self()

    replay = fn replay_path, opts ->
      send(parent, {:replay_started, self()})
      receive do: (:continue_replay -> Log.replay(replay_path, opts))
    end

    starter =
      Task.async(fn ->
        DecisionMetrics.start_link(
          name: nil,
          path: path,
          subscribe?: true,
          replay_fun: replay,
          clock: fn -> @observed_at end
        )
      end)

    assert_receive {:replay_started, writer}, 2_000
    assert Exchange.publish("ticket.42.agent.decision.requested", request_event(35)) >= 1
    send(writer, :continue_replay)
    assert {:ok, metrics} = Task.await(starter)
    on_exit(fn -> stop_if_alive(metrics) end)

    assert {:ok, snapshot} = DecisionMetrics.snapshot("dec-42", metrics)
    assert snapshot.requested_at == DateTime.to_iso8601(@requested_at)
  end

  test "decision metrics survive run log rotation while operator-wait metrics remain run-local", %{tmp_dir: tmp_dir} do
    previous = remember_env([:log_file, :decision_state_dir, :decision_metrics_path, :operator_wait_metrics_path])
    state_dir = Path.join(tmp_dir, "decision-state")
    Application.put_env(:aiur, :log_file, Path.join([tmp_dir, "run-a", "aiur.log"]))
    Application.put_env(:aiur, :decision_state_dir, state_dir)
    Application.delete_env(:aiur, :decision_metrics_path)
    Application.delete_env(:aiur, :operator_wait_metrics_path)
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    decision_path = Path.join([state_dir, "metrics", "decision_latency.ndjson"])
    assert DecisionMetrics.metrics_file() == decision_path
    assert OperatorWaitLog.metrics_file() == Path.join([tmp_dir, "run-a", "metrics", "operator_message_wait.ndjson"])

    first_run = start_metrics!(decision_path)
    assert :ok = DecisionMetrics.observe(request_event(36), first_run)
    GenServer.stop(first_run)

    Application.put_env(:aiur, :log_file, Path.join([tmp_dir, "run-b", "aiur.log"]))
    assert DecisionMetrics.metrics_file() == decision_path
    assert OperatorWaitLog.metrics_file() == Path.join([tmp_dir, "run-b", "metrics", "operator_message_wait.ndjson"])

    second_run = start_metrics!(decision_path)
    on_exit(fn -> stop_if_alive(second_run) end)
    assert :ok = DecisionMetrics.observe(lifecycle_event(37, "answered", 750), second_run)
    assert {:ok, snapshot} = DecisionMetrics.snapshot("dec-42", second_run)
    assert snapshot.request_to_decision_ms == 750
  end

  test "uses resolution as the blocked-time endpoint when acknowledgement is absent", %{tmp_dir: tmp_dir} do
    metrics = start_metrics!(Path.join(tmp_dir, "resolved-blocked-time.ndjson"))
    on_exit(fn -> stop_if_alive(metrics) end)

    assert :ok = DecisionMetrics.observe(request_event(40), metrics)
    assert :ok = DecisionMetrics.observe(lifecycle_event(41, "resolved", 5_000), metrics)
    assert {:ok, snapshot} = DecisionMetrics.snapshot("dec-42", metrics)
    assert snapshot.blocked_time_ms == 5_000
    assert snapshot.delivery_to_ack_ms == nil
  end

  test "backfills canonical requests when their live notification was missed", %{tmp_dir: tmp_dir} do
    previous_state_dir = Application.get_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, Path.join(tmp_dir, "canonical-state"))
    on_exit(fn -> restore_env(:decision_state_dir, previous_state_dir) end)

    {:ok, store} = DecisionStore.start_link(name: nil, filesystem_sync_fun: fn -> :ok end)
    on_exit(fn -> stop_if_alive(store) end)
    ticket = %{identifier: "42", title: "Metrics backfill", url: nil}
    source = %{agent_id: "agent-42", session_id: "session-42", event_id: nil}

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{"question" => "Backfill me", "blocking" => true, "source_id" => "backfill"},
               [ticket: ticket, source: source],
               store
             )

    path = Path.join(tmp_dir, "backfilled-decision-latency.ndjson")
    metrics = start_metrics!(path, seed?: true, decision_store: store)
    on_exit(fn -> stop_if_alive(metrics) end)

    assert :ok = DecisionMetrics.await_seed(metrics)
    assert {:ok, snapshot} = DecisionMetrics.snapshot(decision.decision_id, metrics)
    assert snapshot.requested_at == DateTime.to_iso8601(decision.created_at)
    assert :ok = DecisionMetrics.flush(metrics)
    assert File.read!(path) =~ "canonical:requested:#{decision.decision_id}:request"
  end

  test "metrics_file/0 follows the configurable path override", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "configured-decision-metrics.ndjson")
    previous = Application.get_env(:aiur, :decision_metrics_path)
    Application.put_env(:aiur, :decision_metrics_path, path)
    on_exit(fn -> restore_env(:decision_metrics_path, previous) end)

    assert DecisionMetrics.metrics_file() == path
  end

  defp start_metrics!(path, opts \\ []) do
    defaults = [name: nil, path: path, subscribe?: false, seed?: false, clock: fn -> @observed_at end]

    {:ok, pid} =
      defaults
      |> Keyword.merge(opts)
      |> DecisionMetrics.start_link()

    pid
  end

  defp request_event(id) do
    %{
      id: "canonical:test:#{id}",
      topic: "ticket.42.agent.decision.requested",
      decision_id: "dec-42",
      ticket: %{identifier: "42"},
      blocking: true,
      created_at: DateTime.to_iso8601(@requested_at)
    }
  end

  defp lifecycle_event(id, suffix, offset_ms, extra \\ %{}) do
    Map.merge(
      %{
        id: "canonical:test:#{id}",
        topic: "ticket.42.agent.decision.#{suffix}",
        event_type: suffix,
        decision_id: "dec-42",
        at: @requested_at |> DateTime.add(offset_ms, :millisecond) |> DateTime.to_iso8601()
      },
      extra
    )
  end

  defp remember_env(keys), do: Map.new(keys, &{&1, Application.get_env(:aiur, &1)})
  defp stop_if_alive(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid))

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
