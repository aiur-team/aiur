Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.TagsTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.Commands.{ComponentState, HostApi, Scope, Tags}
  alias Aiur.DecisionApi.PublicProjection

  @operator [actor: %{kind: :operator, id: "operator-1"}]

  setup_all do: :ok = Aiur.TestSupport.ensure_runtime_children_running()

  defp ask(pid, question, tags, ticket \\ "979") do
    payload = %{question: question, blocking: false, options: [%{id: "yes", label: "Yes"}], tags: tags}
    assert {:ok, %{status: :accepted, decision: decision}} = request(pid, payload, ticket: %{@ticket | identifier: ticket})
    decision
  end

  describe "validation" do
    test "accepts bounded slugs, keeps order and drops duplicates" do
      assert {:ok, ["group:p-7", "source:settings.v2", "urgent"]} = Tags.normalize(["group:p-7", "source:settings.v2", "urgent", "urgent"])
      assert {:ok, []} = Tags.normalize(nil)
    end

    test "refuses invalid tags with a named error" do
      assert {:error, {:tags, :invalid_type}} = Tags.normalize("group:a")
      assert {:error, {:tags, :invalid_type}} = Tags.normalize([1])
      assert {:error, {:tags, :too_many}} = Tags.normalize(Enum.map(1..9, &"t#{&1}"))
      assert {:error, {:tags, :too_long}} = Tags.normalize(["source:" <> String.duplicate("a", 90)])
      assert {:error, {:tags, :invalid_slug}} = Tags.normalize(["Group:A"])
      assert {:error, {:tags, :invalid_slug}} = Tags.normalize(["has space"])
      assert {:error, {:tags, :multiple_groups}} = Tags.normalize(["group:a", "group:b"])
    end

    test "decision.requested refuses invalid tags and writes nothing", %{dir: dir} do
      pid = start_store!(dir)
      assert {:error, {:decision_invalid, {:tags, :invalid_slug}}} = request(pid, %{question: "Bad tags?", blocking: false, tags: ["BAD TAG"]})
      assert [] = DecisionStore.list(pid)
      GenServer.stop(pid)
    end
  end

  test "tags persist across a restart and appear in the component map and lifecycle events", %{dir: dir} do
    pid = start_store!(dir)
    :ok = Exchange.subscribe("ticket.979.agent.decision.#")
    decision = ask(pid, "Ship the tagged proposal?", ["group:p-1", "source:settings"])
    assert decision.tags == ["group:p-1", "source:settings"]

    GenServer.stop(pid)
    pid = start_store!(dir)
    assert {:ok, %{tags: ["group:p-1", "source:settings"]} = replayed} = DecisionStore.get(decision.decision_id, pid)

    component = replayed |> PublicProjection.encode() |> ComponentState.from_projection()
    assert component["tags"] == ["group:p-1", "source:settings"]

    assert {:ok, _} = answer(pid, decision.decision_id, %{expected_version: 1, option_id: "yes", idempotency_key: "tag-answer"})
    assert_receive {:event, %{topic: "ticket.979.agent.decision.answered"} = answered}, 1_000
    assert answered["tags"] == ["group:p-1", "source:settings"]

    other = ask(pid, "Keep the second tagged proposal?", ["source:settings"])
    assert {:ok, _} = DecisionStore.moot(other.decision_id, %{reason_class: "ticket_closed"}, @operator, pid)
    assert_receive {:event, %{topic: "ticket.979.agent.decision.mooted"} = mooted}, 1_000
    assert mooted["tags"] == ["source:settings"]
    GenServer.stop(pid)
  end

  test "host API list filters by tag within the grant scope", %{dir: dir} do
    pid = start_store!(dir)
    in_scope = ask(pid, "In-scope tagged question?", ["source:chess"], "42")
    _untagged = ask(pid, "In-scope untagged question?", ["source:go"], "42")
    _out_of_scope = ask(pid, "Hidden tagged question?", ["source:chess"], "99")
    {:ok, %{scope: scope}} = Scope.mint("player-7", ["42"], secret: String.duplicate("s", 64), now: DateTime.utc_now())

    assert {:ok, page} = HostApi.list(scope, %{"tag" => "source:chess"}, store: pid)
    assert Enum.map(page["commands"], & &1["decision_id"]) == [in_scope.decision_id]
    assert page["commands"] |> hd() |> Map.fetch!("tags") == ["source:chess"]
    assert {:error, {:invalid_query, {:tag, :invalid}}} = HostApi.list(scope, %{"tag" => "NOT A TAG"}, store: pid)
    GenServer.stop(pid)
  end

  test "rejecting one Command moots open siblings in its group only", %{dir: dir} do
    pid = start_store!(dir)
    rejected = ask(pid, "Adopt proposal A?", ["group:a"])
    sibling = ask(pid, "Which color for proposal A?", ["group:a"])
    deferred = ask(pid, "Which name for proposal A?", ["group:a"])
    other_group = ask(pid, "Adopt proposal B?", ["group:b"])
    other_ticket = ask(pid, "Adopt proposal A elsewhere?", ["group:a"], "980")
    assert {:ok, _} = DecisionStore.defer(deferred.decision_id, @operator, pid)

    assert {:ok, %{status: :accepted}} = DecisionStore.dismiss(rejected.decision_id, @operator, pid)

    for id <- [sibling.decision_id, deferred.decision_id] do
      assert {:ok, %{decision_status: :moot} = mooted} = DecisionStore.get(id, pid)
      assert mooted.answer == nil
    end

    {:ok, events} = DecisionStore.audit_history(sibling.decision_id, pid)
    moot_event = Enum.find(events, &match?(%DecisionEvent{type: :decision_mooted}, &1))
    assert moot_event.data.reason_class == "sibling_rejected"
    assert moot_event.data.detail =~ rejected.decision_id
    assert moot_event.data.actor.id == "sibling-rejected:" <> rejected.decision_id

    assert {:ok, %{decision_status: :open}} = DecisionStore.get(other_group.decision_id, pid)
    assert {:ok, %{decision_status: :open}} = DecisionStore.get(other_ticket.decision_id, pid)
    GenServer.stop(pid)
  end

  test "a decided-and-delivered sibling keeps its answer when the group is rejected", %{dir: dir} do
    parent = self()

    dispatcher = fn decision, opts ->
      item = correlated_queue_item(decision, Decision.active_answer(decision), opts[:attempt_id], System.unique_integer([:positive]))
      send(parent, {:dispatched, item})
      {:ok, %{status: :accepted, item: item}}
    end

    pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, reconcile_delay_ms: 0, retry_delays_ms: [])
    rejected = ask(pid, "Adopt proposal C?", ["group:c"])
    decided = ask(pid, "Which size for proposal C?", ["group:c"])
    assert {:ok, _} = answer(pid, decided.decision_id, %{expected_version: 1, option_id: "yes", idempotency_key: "decided-sibling"})
    assert_receive {:dispatched, item}, 5_000
    _queued = wait_for_decision(pid, decided.decision_id, &(&1.delivery_status == :queued))
    assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
    assert %{decision_status: :decided} = wait_for_decision(pid, decided.decision_id, &Decision.delivered?/1)

    assert {:ok, %{status: :accepted}} = DecisionStore.dismiss(rejected.decision_id, @operator, pid)
    assert {:ok, %{decision_status: :decided, answer: %{selected_option_id: "yes"}}} = DecisionStore.get(decided.decision_id, pid)
    assert DecisionStore.health(pid) == :writable
    GenServer.stop(pid)
  end

  test "a host rejection moots the open siblings in its group", %{dir: dir} do
    pid = start_store!(dir)
    rejected = ask(pid, "Adopt proposal E?", ["group:e"], "42")
    sibling = ask(pid, "Which color for proposal E?", ["group:e"], "42")
    other = ask(pid, "Adopt proposal F?", ["group:f"], "42")
    {:ok, %{scope: scope}} = Scope.mint("player-7", ["42"], secret: String.duplicate("s", 64), now: DateTime.utc_now())
    payload = %{"reason" => "Proposal E is out of scope.", "expected_version" => 1, "idempotency_key" => "reject-e"}

    assert {:ok, %{"command" => %{"state" => "rejected"}}} = HostApi.reject(scope, rejected.decision_id, payload, store: pid)
    assert {:ok, %{decision_status: :moot}} = DecisionStore.get(sibling.decision_id, pid)
    assert {:ok, %{decision_status: :open}} = DecisionStore.get(other.decision_id, pid)
    GenServer.stop(pid)
  end

  # Only open siblings are mooted; an undelivered answer is withdrawable but is not "open".
  test "a decided-but-undelivered sibling keeps its answer when the group is rejected", %{dir: dir} do
    pid = start_store!(dir, dispatcher: fn _decision, _opts -> {:error, :unavailable} end, dispatch_delay_ms: 0, retry_delays_ms: [])
    rejected = ask(pid, "Adopt proposal D?", ["group:d"])
    decided = ask(pid, "Which size for proposal D?", ["group:d"])
    assert {:ok, _} = answer(pid, decided.decision_id, %{expected_version: 1, option_id: "yes", idempotency_key: "undelivered-sibling"})
    refute Decision.delivered?(elem(DecisionStore.get(decided.decision_id, pid), 1))

    assert {:ok, %{status: :accepted}} = DecisionStore.dismiss(rejected.decision_id, @operator, pid)
    assert {:ok, %{decision_status: :decided}} = DecisionStore.get(decided.decision_id, pid)
    GenServer.stop(pid)
  end
end
