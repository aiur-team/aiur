Code.require_file("journal_support.exs", __DIR__)

defmodule Aiur.Conversation.ThreadEventsTest do
  use ExUnit.Case, async: false
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{Ingest, Ref, TestSupport}
  alias Aiur.Events.{Catalog, Exchange, Publisher}

  setup context do
    context = TestSupport.setup(context)
    tracked = :persistent_term.get({Publisher, :tracked_fn}, :absent)
    Publisher.set_tracked_fn(fn _ -> true end)

    on_exit(fn ->
      case tracked do
        :absent -> :persistent_term.erase({Publisher, :tracked_fn})
        fun -> Publisher.set_tracked_fn(fun)
      end
    end)

    number = System.unique_integer([:positive])
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "node-#{number}", "number" => number}, {"o", "r"}, {"o", "r"})
    {:ok, worker} = Ref.worker(identity)
    topic = "ticket.#{number}.agent.thread.changed"
    :ok = Exchange.subscribe(topic)
    Map.merge(context, %{worker: worker, topic: topic})
  end

  test "a journal batch holding a message publishes one identifier-only thread change at the batch head", %{worker: worker, topic: topic, now: now} do
    assert %{pattern: "ticket.*.agent.thread.changed", export?: true, owner: "conversations"} = Catalog.lookup(topic)

    events = [
      %{role: "assistant", msg_id: "m1", body: "secret plan", timestamp: now},
      %{role: "user", msg_id: "operator:5", body: "go", timestamp: now, payload: %{delivery_id: "5"}},
      %{role: "reasoning", msg_id: "r1", body: "thinking", timestamp: now}
    ]

    Ingest.append(worker, %{source() | role: :worker}, events)
    assert :ok = flush(worker)
    assert_receive {:event, %{topic: ^topic} = event}, 100
    assert Map.take(event, [:head_pos, :kind]) == %{head_pos: 3, kind: "operator_message"}
    refute Enum.any?(Map.values(event), &(&1 == "secret plan"))
    refute_received {:event, %{topic: ^topic}}
  end

  test "a batch without agent or operator messages publishes nothing", %{worker: worker, topic: topic, now: now} do
    Ingest.append(worker, %{source() | role: :worker}, [%{role: "reasoning", msg_id: "r1", body: "thinking", timestamp: now}])
    assert :ok = flush(worker)
    refute_receive {:event, %{topic: ^topic}}, 100
  end
end
