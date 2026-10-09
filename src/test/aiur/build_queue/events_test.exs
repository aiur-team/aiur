Code.require_file("../../support/build_queue_fake_tracker.ex", __DIR__)

defmodule Aiur.BuildQueue.EventsTest do
  use Aiur.TestSupport
  alias Aiur.BuildQueue.{Bookkeeping, Events, Model, Writer}
  alias Aiur.BuildQueueFakeTracker, as: Fake
  alias Aiur.Events.Exchange
  alias Aiur.GitHub.Config, as: GitHubConfig

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_bot_account: "queue-daemon")
    id = "3070" <> Integer.to_string(System.unique_integer([:positive]))
    queue = %Model.Queue{id: "q-0001", name: "Private title", kind: :list, root: nil, held: false, generation: 0, created_at: ~U[2026-10-08 00:00:00Z]}
    item = %Model.Item{issue_id: id, queue_id: queue.id, position: 1, hold: nil, override: nil, promoted_at: nil, added_at: queue.created_at}
    document = %{queues: [queue], items: [item], edges: [], intents: [], latches: []}
    Fake.reset(document)
    :ok = Exchange.subscribe("ticket.#{id}.queue.*")
    %{document: document, item: item, id: id}
  end

  test "promotion publishes once after its outcome is saved with reference-only payload", %{document: document, id: id} do
    result = run(document, [{:promote, id}])
    event = event(id, "promoted", "promote")
    assert Map.drop(event, [:id, :topic, :ticket_observation]) == %{"ticket" => id, "queue_id" => "q-0001", "cause" => "promote"}
    assert [%{outcome: :ok}] = Fake.get(:document).intents
    assert :ok = Events.saved(result.document, result.document)
    barrier()
    topic = event.topic
    refute_received {:event, %{topic: ^topic}}
  end

  test "reprocessing the same successful intent is deduped", %{document: document, id: id} do
    result = run(document, [{:promote, id}])
    event(id, "promoted", "promote")
    assert :ok = Events.saved(document, result.document)
    barrier()
    topic = "ticket.#{id}.queue.promoted"
    refute_received {:event, %{topic: ^topic}}
  end

  test "internal transitions survive the configured daemon actor filter", %{item: item, id: id} do
    assert GitHubConfig.daemon_account() == "queue-daemon"
    assert :ok = Events.publish(:promoted, Map.put(item, :title, "Private title"), :promote, Ecto.UUID.generate())
    event = event(id, "promoted", "promote")
    assert Map.drop(event, [:id, :topic, :ticket_observation]) == %{"ticket" => id, "queue_id" => "q-0001", "cause" => "promote"}
  end

  test "a saved successful withdrawal emits the withdrawn verb", %{document: document, id: id} do
    intent = %Model.Intent{id: Ecto.UUID.generate(), issue_id: id, action: :withdraw, target_labels: ["agent:queued"], recorded_at_ms: 1_000, outcome: nil}
    pending = %{document | intents: [intent]}
    saved = %{pending | intents: [%{intent | outcome: :ok}]}
    :ok = Events.saved(pending, saved)
    event(id, "withdrawn", "withdraw")
  end

  test "future guard: tracker and outcome-save failures emit no promotion", %{document: document, id: id} do
    Fake.put(:save_failure_at, 2)
    assert run(document, [{:promote, id}]).status == :store_unavailable
    Fake.reset(document)
    Fake.put(:result, {:error, :stale_observation})
    run(document, [{:promote, id}])
    barrier()
    topic = "ticket.#{id}.queue.promoted"
    refute_received {:event, %{topic: ^topic}}
  end

  test "saved bookkeeping emits hold, override and removal only once", %{document: document, id: id} do
    held = run(document, [{:mark_external_hold, id}]).document
    event(id, "held", "external")
    run(held, [{:mark_external_hold, id}])
    barrier()
    topic = "ticket.#{id}.queue.held"
    refute_received {:event, %{topic: ^topic}}
    overridden = run(held, [{:mark_override, id}]).document
    event(id, "overridden", "manual_promotion")
    run(overridden, [{:dequeue, id}])
    event(id, "removed", "marker_removed")
  end

  test "saved item and queue releases emit a release only when a hold clears", %{document: document, id: id} do
    held = %{document | queues: Enum.map(document.queues, &%{&1 | held: true})}
    observations = %{id => %{labels: []}}
    {:ok, released} = Bookkeeping.release(held, "q-0001", observations, 1_000, "agent:todo")
    :ok = Events.saved(held, released)
    event(id, "released", "operator")
    :ok = Events.saved(released, released)
    barrier()
    topic = "ticket.#{id}.queue.released"
    refute_received {:event, %{topic: ^topic}}
  end

  test "future guard: failed bookkeeping saves do not publish", %{document: document, id: id} do
    Fake.put(:save_result, {:error, :disk_full})
    assert run(document, [{:mark_external_hold, id}]).status == :store_unavailable
    barrier()
    topic = "ticket.#{id}.queue.held"
    refute_received {:event, %{topic: ^topic}}
  end

  defp run(document, actions) do
    observation = %Model.Observation{issue_id: hd(document.items).issue_id, open?: true, labels: ["agent:queued"], state_reason: nil, pr: nil, observed_at_ms: Fake.clock()}

    context = %{
      document: document,
      tracker: Fake,
      store: Fake,
      claim_probe: Fake,
      clock: &Fake.clock/0,
      sleep: &Fake.sleep/1,
      marker: "agent:queued",
      todo: "agent:todo",
      max_writes: 20,
      observation_max_age_ms: 120_000,
      observations: %{observation.issue_id => observation}
    }

    Writer.run(context, actions, Writer.new())
  end

  defp event(id, verb, cause) do
    barrier()
    topic = "ticket.#{id}.queue.#{verb}"
    assert_received {:event, %{"ticket" => ^id, "queue_id" => "q-0001", "cause" => ^cause, topic: ^topic} = event}
    event
  end

  defp barrier, do: Exchange.bindings_for(self())
end
