Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.RoutingFactsTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.Commands.Projection
  alias Aiur.Commands.Routing.Facts
  alias Aiur.DecisionApi.PublicProjection
  alias Aiur.Events.Envelope
  alias Aiur.ExecutorEvents

  setup %{dir: dir} do
    previous = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(dir, "executor"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :executor_state_dir, previous), else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    :ok = ExecutorEvents.subscribe("executor.#")
    pid = start_store!(dir)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, %{decision: decision}} = request(pid, %{question: "Private question?", blocking: false})
    %{pid: pid, decision: decision, at: DateTime.utc_now()}
  end

  defp fact(pid, decision, type, data), do: DecisionStore.record_command_fact(decision.decision_id, type, data, server: pid)
  defp route(at, state \\ :with_executor), do: %{policy: :executor_first, state: state, cause: nil, at: at, actor: %{kind: :system, id: "routing"}}
  defp escalation(at), do: %{cause: :executor_ack_timeout, at: at, detail: "No acknowledgement", actor: %{kind: :system, id: "routing"}}
  defp human(at, requester \\ :worker), do: %{cause: :executor_ack_timeout, at: at, short_label: "Private summary", requester_kind: requester, blocking: false, urgency: :normal}

  test "routing and escalation project status-neutral public fields and duplicate once", %{pid: pid, decision: d, at: at} do
    assert {:ok, %{decision: routed}} = fact(pid, d, :routed, route(at))
    assert routed.route_state == :with_executor
    assert routed.routed_at == at
    assert routed.human_visible_at == nil
    later = DateTime.add(at, 1, :second)
    assert {:ok, %{status: :accepted, decision: escalated}} = fact(pid, d, :escalated, escalation(later))
    assert escalated.route_state == :with_human
    assert escalated.human_visible_at == later
    assert escalated.escalations == [%{cause: :executor_ack_timeout, at: later, detail: "No acknowledgement", decision_version: 1}]
    assert {escalated.version, escalated.decision_status, escalated.delivery_status} == {1, :open, :not_dispatched}
    assert {:ok, %{status: :duplicate, decision: ^escalated}} = fact(pid, d, :escalated, escalation(later))

    for encoded <- [PublicProjection.encode(escalated), DecisionProjection.to_json_safe(escalated)] do
      assert encoded["route_policy"] == "executor_first"
      assert encoded["route_state"] == "with_human"
      assert encoded["human_visible_at"] == DateTime.to_iso8601(later)
      assert encoded["escalations"] == [%{"cause" => "executor_ack_timeout", "at" => DateTime.to_iso8601(later), "detail" => "No acknowledgement", "decision_version" => 1}]
      assert encoded["executor_acknowledged_at"] == nil
    end

    assert Projection.public_v2(escalated).human_visible_at == later
    assert {:ok, history} = DecisionStore.audit_history(d.decision_id, pid)
    assert Enum.count(history, &(&1.type == :escalated)) == 1
  end

  test "human-needed publishes once with no question content and survives replay and version updates", %{pid: pid, decision: d, dir: dir, at: at} do
    topic = "ticket.979.agent.decision.human-needed"
    :ok = Exchange.subscribe(topic)
    assert {:error, {:invalid_transition, :command_not_human_visible}} = fact(pid, d, :human_needed, human(at))
    assert {:ok, _} = fact(pid, d, :routed, route(at, :with_human))
    assert {:ok, %{status: :accepted}} = fact(pid, d, :human_needed, Map.merge(human(at), %{question: "Secret", options: ["Secret"], context: %{secret: true}}))
    id = d.decision_id
    receive_barrier({:event, %{"decision_id" => ^id, topic: ^topic} = payload})
    assert payload["data"]["short_label"] == "Private summary"
    for container <- [payload, payload["data"]], key <- ["question", "options", "context"], do: refute(Map.has_key?(container, key))
    assert {:ok, envelope} = Envelope.to_external(payload, instance: "test")
    assert envelope["attrs"] == %{"requester_kind" => "worker", "blocking" => false, "urgency" => "normal", "cause" => "executor_ack_timeout"}
    assert {:ok, %{status: :duplicate}} = fact(pid, d, :human_needed, human(at))
    refute_received {:event, %{topic: ^topic}}
    GenServer.stop(pid)
    replayed = start_store!(dir)
    on_exit(fn -> if Process.alive?(replayed), do: GenServer.stop(replayed) end)
    assert DecisionStore.health(replayed) == :writable
    assert {:ok, %{status: :duplicate, decision: current}} = fact(replayed, d, :human_needed, human(at))
    assert {:ok, %{decision: enriched}} = enrich(replayed, id, %{"context" => %{"short_summary" => "New evidence"}}, 1, now: at)
    assert enriched.version == 2
    assert enriched.human_needed_at == at
    assert enriched.human_visible_at == current.human_visible_at
    GenServer.stop(replayed)
    enriched_store = start_store!(dir)
    on_exit(fn -> if Process.alive?(enriched_store), do: GenServer.stop(enriched_store) end)
    assert {:ok, %{status: :duplicate, decision: restored}} = fact(enriched_store, d, :human_needed, human(at))
    assert restored.version == 2
    assert restored.human_visible_at == at
    assert {:ok, history} = DecisionStore.audit_history(id, enriched_store)
    assert Enum.count(history, &(&1.type == :human_needed)) == 1
  end

  test "executor human-needed uses its durable topic and exports only typed attributes", %{pid: pid, at: at} do
    assert {:ok, %{decision: d}} = request(pid, %{question: "Executor secret?", blocking: false}, ticket: %{identifier: "executor"}, requester: %{kind: :executor})
    assert {:ok, _} = fact(pid, d, :routed, route(at, :with_human))
    assert {:ok, _} = fact(pid, d, :human_needed, human(at, :executor))
    assert {:ok, [payload]} = ExecutorEvents.replay(["executor.decision.human-needed"], 0)
    assert payload["decision_id"] == d.decision_id
    assert {:ok, envelope} = Envelope.to_external(payload, instance: "test")
    assert envelope["attrs"] == %{"requester_kind" => "executor", "blocking" => false, "urgency" => "normal", "cause" => "executor_ack_timeout"}
    assert envelope["refs"] == %{"decision_id" => d.decision_id, "decision_version" => 1}
    refute Map.has_key?(envelope["attrs"], "short_label")
  end

  test "ack is first-only across replay and public serializers", %{pid: pid, decision: d, dir: dir, at: at} do
    data = %{executor_id: "exec-1", via: :explicit, at: at}
    assert {:ok, %{status: :accepted, decision: acked}} = fact(pid, d, :executor_acknowledged, data)
    assert acked.executor_acknowledged_at == at
    assert PublicProjection.encode(acked)["executor_acknowledged_at"] == DateTime.to_iso8601(at)
    assert {:ok, %{status: :duplicate, decision: ^acked}} = fact(pid, d, :executor_acknowledged, %{data | at: DateTime.add(at, 1)})
    GenServer.stop(pid)
    replayed = start_store!(dir)
    on_exit(fn -> if Process.alive?(replayed), do: GenServer.stop(replayed) end)
    assert {:ok, %{status: :duplicate, decision: ^acked}} = fact(replayed, d, :executor_acknowledged, data)
  end

  test "escalation rejects an answered Command and malformed facts do not append", %{pid: pid, decision: d, at: at} do
    assert {:ok, _} = fact(pid, d, :routed, route(at))
    assert {:ok, _} = answer(pid, d.decision_id, %{"idempotency_key" => "answer", "expected_version" => 1, "custom_response" => "Proceed"})
    assert {:error, {:invalid_transition, :command_not_with_executor}} = fact(pid, d, :escalated, escalation(at))
    assert {:error, {:detail, :too_long}} = fact(pid, d, :escalated, %{escalation(at) | detail: String.duplicate("x", 201)})
    assert {:error, {:state, :invalid_enum}} = fact(pid, d, :routed, %{route(at) | state: "unexpected"})
    assert {:error, {:at, :invalid_timestamp}} = fact(pid, d, :routed, %{route(at) | at: "yesterday"})
    assert {:error, :unsupported_command_fact} = fact(pid, d, :requested, %{})
    assert {:error, :not_found} = fact(pid, %{d | decision_id: "missing"}, :routed, route(at))
    assert {:ok, history} = DecisionStore.audit_history(d.decision_id, pid)
    refute Enum.any?(history, &(&1.type == :escalated))
  end

  test "failed append leaves routing unchanged and retry accepts exactly one fact", %{pid: pid, decision: d, at: at, dir: dir} do
    original = :sys.get_state(pid).ndjson_path
    invalid = Path.join(dir, "missing/decisions.ndjson")
    :sys.replace_state(pid, &%{&1 | ndjson_path: invalid})
    assert {:error, {:append_failed, _reason}} = fact(pid, d, :routed, route(at))
    assert {:ok, unchanged} = DecisionStore.get(d.decision_id, pid)
    assert unchanged.route_state == nil
    :sys.replace_state(pid, &%{&1 | ndjson_path: original})
    assert {:ok, %{status: :accepted, decision: routed}} = fact(pid, d, :routed, route(at))
    assert routed.route_state == :with_executor
    assert {:ok, history} = DecisionStore.audit_history(d.decision_id, pid)
    assert Enum.count(history, &(&1.type == :routed)) == 1
  end

  test "rerouting preserves first visibility and escalation dedup is scoped to version", %{pid: pid, decision: d, at: at} do
    assert {:ok, _} = fact(pid, d, :routed, route(at))
    assert {:ok, _} = fact(pid, d, :escalated, escalation(at))
    assert {:ok, %{decision: current}} = fact(pid, d, :routed, route(DateTime.add(at, 1)))
    assert current.human_visible_at == at
    assert {:ok, %{status: :duplicate}} = fact(pid, d, :escalated, escalation(at))
    assert {:ok, event} = DecisionEvent.new(:escalated, d.decision_id, 2, escalation(at), event_id: "next-version", run_id: "test")
    assert {:ok, updated} = Facts.apply(%{current | version: 2}, event)
    assert length(updated.escalations) == 2
    assert {:error, :version_mismatch} = Facts.apply(current, event)
    assert {:error, :duplicate} = Facts.apply(updated, event)
  end

  test "request snapshots keep their frozen hash shape while routing remains public", %{decision: d, at: at} do
    routed = %{d | route_policy: :human_only, route_state: :with_human, human_visible_at: at}
    assert {:ok, event} = DecisionEvent.new(:requested, d.decision_id, 1, routed, event_id: 444, run_id: "test")
    raw = event |> DecisionEvent.to_json_safe() |> Jason.encode!() |> Jason.decode!()
    for key <- ~w(route_policy route_state routed_at human_visible_at escalations executor_acknowledged_at), do: refute(Map.has_key?(raw["data"], key))
    assert {:ok, _event} = DecisionEvent.from_json_safe(raw)
    assert PublicProjection.encode(routed)["route_state"] == "with_human"
  end

  test "read-only stores reject facts", %{pid: pid, decision: d, at: at} do
    :sys.replace_state(pid, &%{&1 | writable?: false})
    assert {:error, :store_read_only} = fact(pid, d, :routed, route(at))
  end
end
