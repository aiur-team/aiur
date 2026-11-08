Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.AnsweringRetryTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.Commands.Answering

  setup %{dir: dir} do
    store = start_supervised!({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000, answer_comment_publisher: fn _ -> :ok end})
    payload = answerable_request("facade-retry") |> Map.merge(%{"authority" => "supervisor_allowed", "reversibility" => "reversible"})
    {:ok, %{decision: decision}} = request(store, payload)
    %{store: store, decision: decision}
  end

  test "supersede fallback remains an answer retry before and after delivery", ctx do
    id = ctx.decision.decision_id
    assert %{status: :accepted, decision: accepted} = Answering.supersede(id, payload("initial"), opts(ctx, "first"))
    assert %{status: :duplicate} = Answering.supersede(id, payload("initial"), opts(ctx, "second"))

    item = %{
      id: 1,
      target_issue_identifier: accepted.ticket.identifier,
      action_id: accepted.active_action_id,
      correlation: %{decision_id: id, decision_version: accepted.version, action_id: accepted.active_action_id, attempt_id: "attempt"}
    }

    assert {:ok, :accepted} = DecisionStore.record_delivery(item, ctx.store)
    assert %{status: :duplicate, delivery: :delivered} = Answering.supersede(id, payload("initial"), opts(ctx, "third"))
    assert {:ok, %{revisions: []}} = DecisionStore.get(id, ctx.store)
  end

  test "original answer retry preserves provenance after a newer replacement", ctx do
    id = ctx.decision.decision_id
    assert %{status: :accepted} = Answering.answer(id, payload("initial"), opts(ctx, "first"))
    assert %{status: :accepted, decision: current} = Answering.supersede(id, payload("replacement"), opts(ctx, "second"))
    assert %{status: :duplicate, decision: replayed} = Answering.answer(id, payload("initial"), opts(ctx, "third"))
    assert replayed.active_action_id == current.active_action_id
    assert replayed.answer.actor.id == "device:first"
  end

  test "historical supersede retry is duplicate across devices after a newer replacement", ctx do
    id = ctx.decision.decision_id
    assert %{status: :accepted} = Answering.answer(id, payload("initial"), opts(ctx, "first"))
    assert %{status: :accepted} = Answering.supersede(id, payload("replacement"), opts(ctx, "second"))
    assert %{status: :accepted, decision: current} = Answering.supersede(id, payload("newest"), opts(ctx, "third"))
    assert %{status: :duplicate, decision: replayed} = Answering.supersede(id, payload("replacement"), opts(ctx, "fourth"))
    assert replayed.active_action_id == current.active_action_id
    assert Decision.active_answer(replayed).actor.id == "device:third"
  end

  test "two devices reading the unanswered command before either write safely retry one key", ctx do
    store = ctx.store
    id = ctx.decision.decision_id
    :ok = :sys.suspend(store)

    tasks =
      for device <- ["first", "second"] do
        task =
          Task.async(fn ->
            receive do
              :submit -> Answering.answer(id, payload("same-key"), opts(ctx, device))
            end
          end)

        :erlang.trace(task.pid, true, [:send])
        task
      end

    try do
      Enum.each(tasks, &send(&1.pid, :submit))

      for task <- tasks do
        pid = task.pid
        receive_barrier({:trace, ^pid, :send, {:"$gen_call", _from, {:get, ^id}}, ^store})
        :erlang.trace(pid, false, [:send])
      end
    after
      :sys.resume(store)
    end

    results = Enum.map(tasks, &Task.await(&1, :infinity))
    assert Enum.sort(Enum.map(results, & &1.status)) == [:accepted, :duplicate]
    [first, second] = Enum.map(results, & &1.decision.answer)
    assert first == second
  end

  defp opts(ctx, device), do: [store: ctx.store, actor: %{kind: :operator, id: "human"}, actor_source: :device, client: %{surface: :phone, device_id: device}]
  defp payload(key), do: %{expected_version: 1, idempotency_key: key, custom_response: "Proceed", rationale: "Operator choice"}
end
