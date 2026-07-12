defmodule Aiur.DecisionMetricsCanonicalTest do
  use ExUnit.Case, async: false

  alias Aiur.DecisionMetrics
  alias Aiur.DecisionStore

  @moduletag :tmp_dir
  @requested_at ~U[2026-07-12 12:00:00.000Z]

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, Path.join(tmp_dir, "canonical-state"))
    on_exit(fn -> restore_env(:decision_state_dir, previous) end)

    {:ok, store} = DecisionStore.start_link(name: nil, filesystem_sync_fun: fn -> :ok end)
    on_exit(fn -> stop_if_alive(store) end)

    ticket = %{identifier: "42", title: "Canonical metrics", url: nil}
    source = %{agent_id: "agent-42", session_id: "session-42", event_id: nil}
    %{store: store, ticket: ticket, source: source}
  end

  test "correlates OCC-2 reminders without duplicating its adapter", context do
    topic = "ticket.42.agent.attention.operator-decision"

    opts = [
      ticket: context.ticket,
      source: context.source,
      legacy_attention: %{slug: "operator-decision", topic: topic}
    ]

    assert {:ok, %{decision: first}} =
             DecisionStore.project_attention(
               %{
                 "source_id" => "legacy_attention:operator-decision",
                 "kind" => "legacy_attention",
                 "question" => "Choose a path",
                 "blocking" => true,
                 "options" => []
               },
               opts,
               context.store
             )

    assert {:ok, %{decision: decision}} =
             DecisionStore.project_attention(
               %{
                 "source_id" => "legacy_attention:operator-decision",
                 "kind" => "legacy_attention",
                 "question" => "Choose an updated path",
                 "blocking" => true,
                 "options" => []
               },
               opts,
               context.store
             )

    assert decision.version == first.version + 1
    metrics = start_metrics!(context.tmp_dir, context.store)
    assert :ok = DecisionMetrics.await_seed(metrics)
    assert :ok = DecisionMetrics.observe(attention_event(1, topic, 1_000), metrics)
    assert :ok = DecisionMetrics.observe(attention_event(2, topic, 2_000), metrics)

    assert {:ok, snapshot} = DecisionMetrics.snapshot(decision.decision_id, metrics)
    assert snapshot.attention_count == 2
    assert snapshot.reminder_count == 1
    refute snapshot.revised
  end

  test "backfills the OCC-3 current projection shape after a missed publication", context do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{"question" => "Ship?", "blocking" => true, "source_id" => "occ3-shape"},
               [ticket: context.ticket, source: context.source, now: @requested_at],
               context.store
             )

    revised_at = DateTime.add(@requested_at, 500, :millisecond)

    assert {:ok, %{decision: revised}} =
             DecisionStore.request(
               %{
                 "question" => "Ship with the updated plan?",
                 "blocking" => true,
                 "source_id" => "occ3-shape",
                 "version" => 2
               },
               [ticket: context.ticket, source: context.source, now: revised_at],
               context.store
             )

    projected =
      revised
      |> Map.put(:answer, %{
        action_id: "act-1",
        accepted_at: DateTime.add(decision.created_at, 1_000, :millisecond),
        actor: %{kind: :operator, id: "operator-1"}
      })
      |> Map.put(:dispatch_attempts, [
        %{
          attempt_id: "attempt-failed-before-queue",
          attempted_at: DateTime.add(decision.created_at, 1_500, :millisecond),
          queued_at: nil,
          delivered_at: nil
        },
        %{
          attempt_id: "attempt-1",
          attempted_at: DateTime.add(decision.created_at, 2_000, :millisecond),
          queued_at: DateTime.add(decision.created_at, 2_000, :millisecond),
          delivered_at: DateTime.add(decision.created_at, 3_000, :millisecond)
        }
      ])
      |> Map.put(:acknowledgement, %{occurred_at: DateTime.add(decision.created_at, 4_000, :millisecond)})

    :sys.replace_state(context.store, fn state ->
      %{state | current: Map.put(state.current, decision.decision_id, projected)}
    end)

    metrics = start_metrics!(context.tmp_dir, context.store)
    assert :ok = DecisionMetrics.await_seed(metrics)
    assert {:ok, snapshot} = DecisionMetrics.snapshot(decision.decision_id, metrics)
    assert snapshot.request_to_decision_ms == 1_000
    assert snapshot.decision_to_dispatch_ms == 1_000
    assert snapshot.dispatch_to_delivery_ms == 1_000
    assert snapshot.delivery_to_ack_ms == 1_000
    assert snapshot.blocked_time_ms == 4_000
    assert snapshot.actor == "human"
    assert snapshot.revised
  end

  defp start_metrics!(tmp_dir, store) do
    path = Path.join(tmp_dir, "canonical-decision-metrics.ndjson")

    {:ok, metrics} =
      DecisionMetrics.start_link(
        name: nil,
        path: path,
        subscribe?: false,
        seed?: true,
        decision_store: store
      )

    on_exit(fn -> stop_if_alive(metrics) end)
    metrics
  end

  defp attention_event(id, topic, offset_ms) do
    %{
      id: id,
      type: "alert",
      topic: topic,
      created_at: @requested_at |> DateTime.add(offset_ms, :millisecond) |> DateTime.to_iso8601()
    }
  end

  defp stop_if_alive(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid))

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
