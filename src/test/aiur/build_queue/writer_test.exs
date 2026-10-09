Code.require_file("../../support/build_queue_fake_tracker.ex", __DIR__)

defmodule Aiur.BuildQueue.WriterTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildQueue.{Model, Planner, Writer}
  alias Aiur.BuildQueueFakeTracker, as: Fake

  setup do
    document = document(3)
    Fake.reset(document)
    %{document: document}
  end

  test "AC2: planner downstream rank determines three independent promotion calls" do
    document = document(5)
    edges = for {prerequisite, dependent} <- [{"3", "4"}, {"3", "5"}, {"2", "5"}], do: %Model.Edge{prerequisite: prerequisite, dependent: dependent, source: :native}
    document = %{document | edges: edges}
    {_, actions} = Planner.plan(input(document))
    result = run(document, actions)
    assert calls() == [promote("3"), promote("2"), promote("1"), {:notify_demand, ["3", "2", "1"]}]
    promoted = Enum.filter(result.document.items, &(&1.promoted_at != nil))
    assert Enum.map(promoted, & &1.issue_id) == ["1", "2", "3"]
    assert Enum.all?(promoted, &(&1.promoted_at == DateTime.from_unix!(1_000, :millisecond)))
    assert Enum.all?(result.document.intents, &(&1.outcome == :ok))
  end

  test "AC1 and AC10: dependent waits for completed prerequisite and duplicate reconcile writes nothing", %{document: document} do
    document = %{document | items: Enum.take(document.items, 2), edges: [%Model.Edge{prerequisite: "1", dependent: "2", source: :native}]}
    {_, actions} = Planner.plan(input(document))
    first = run(document, actions)
    assert calls() == [promote("1"), {:notify_demand, ["1"]}]
    {states, again} = Planner.plan(input(first.document))
    assert Enum.find(states, &(&1.issue_id == "1")).reason == :awaiting_promotion_observation
    assert again == []
    Fake.put(:now, 2_000)
    observations = input(first.document).observations |> Map.update!("1", &%{&1 | open?: false, state_reason: "completed", observed_at_ms: 2_000})
    {_, next} = Planner.plan(%{input(first.document) | observations: observations})
    run(first.document, next, first.writer)
    assert calls() == [promote("1"), {:notify_demand, ["1"]}, promote("2"), {:notify_demand, ["2"]}]
  end

  test "pacing: 30 ready at 20 per minute writes 20 now and 10 next window" do
    document = document(30)
    Fake.reset(document)
    actions = Enum.map(document.items, &{:promote, &1.issue_id})
    first = run(document, actions)
    assert first.status == :paced
    assert length(first.document.intents) == 20
    remaining = Enum.drop(actions, 20)
    waiting = run(first.document, remaining, first.writer)
    assert length(waiting.document.intents) == 20
    Fake.put(:now, 61_000)
    final = run(waiting.document, remaining, waiting.writer)
    assert final.status == :running
    assert length(final.document.intents) == 30
    assert Enum.map(final.document.intents, & &1.issue_id) == Enum.map(1..30, &to_string/1)
  end

  test "intent is saved before call with complete target labels; save failure makes no call", %{document: document} do
    run(document, [{:promote, "1"}])
    [{_, saved}, _] = Fake.get(:calls)
    assert [%{action: :promote, outcome: nil, issue_id: "1", target_labels: ["agent:queued", "agent:todo"]}] = saved.intents
    Fake.reset(document)
    Fake.put(:save_result, {:error, :disk_full})
    result = run(document, [{:promote, "1"}])
    assert result.status == :store_unavailable
    assert calls() == []
  end

  test "outcome save failure stops batch and leaves durable pending intent", %{document: document} do
    Fake.put(:save_failure_at, 2)
    result = run(document, [{:promote, "1"}, {:promote, "2"}])
    assert result.status == :store_unavailable
    assert calls() == [promote("1")]
    assert [%{issue_id: "1", outcome: nil}] = Fake.get(:document).intents
    assert hd(Fake.get(:document).items).promoted_at == nil
  end

  test "conditional promotion refuses a human lifecycle label", %{document: document} do
    Fake.put(:labels, %{"1" => ["agent:queued", "agent:in-progress"]})
    result = run(document, [{:promote, "1"}])
    assert [%{outcome: {:error, {:stale_issue_state, :none, ["agent:in-progress"]}}}] = result.document.intents
    assert Fake.get(:labels)["1"] == ["agent:queued", "agent:in-progress"]
    assert result.writer.failures == %{}
  end

  test "stale state and closed issue are reobserved without retries or failure counts", %{document: document} do
    for reason <- [{:stale_issue_state, :none, "in-progress"}, {:no_state_label_written, "closed"}] do
      Fake.reset(document)
      Fake.put(:result, {:error, reason})
      result = run(document, [{:promote, "1"}])
      assert result.writer.failures == %{}
      assert calls() == [promote("1")]
      assert hd(result.document.items).promoted_at == nil
    end
  end

  test "budget errors stop batch, unsuccessful probe stays paused and successful probe resumes", %{document: document} do
    for reason <- [{:github, :local_hold, %{}}, {:github, :rate_limited, %{}}, {:aiur, :locally_held, %{}}] do
      Fake.reset(document)
      Fake.put(:result, {:error, reason})
      paused = run(document, [{:promote, "1"}, {:promote, "2"}])
      assert paused.status == :writes_paused
      assert calls() == [promote("1")]
      assert paused.writer.failures == %{}
      Fake.put(:result, {:error, {:stale_issue_state, :none, "in-progress"}})
      probe = run(paused.document, [{:promote, "1"}, {:promote, "2"}], paused.writer)
      assert probe.status == :writes_paused
      assert calls() == [promote("1"), promote("1")]
      Fake.put(:result, :ok)
      resumed = run(probe.document, [{:promote, "2"}, {:promote, "3"}], probe.writer)
      assert resumed.status == :running
      assert Enum.take(calls(), -3) == [promote("2"), promote("3"), {:notify_demand, ["2", "3"]}]
    end
  end

  test "five consecutive failed attempts latch write_failed once and use bounded backoff", %{document: document} do
    Fake.put(:result, {:error, :unavailable})
    first = run(document, [{:promote, "1"}])
    assert first.writer.failures == %{"1" => 4}
    assert Fake.get(:delays) == [1_000, 4_000, 16_000]
    next = run(first.document, [{:promote, "1"}], first.writer)
    assert next.write_attentions == [{:attention_open, {:write_failed, "1"}}]
    last = run(next.document, [{:promote, "1"}], next.writer)
    assert last.write_attentions == []
    assert [%{key: {:write_failed, "1"}}] = last.document.latches
  end

  test "marker ensure happens once per boot, is paced, and failure prevents marker add", %{document: document} do
    result = run(document, [{:mark, "1"}, {:mark, "2"}, {:unmark, "1"}])
    assert calls() == [{:ensure_labels, ["agent:queued"]}, {:add_label, "1", "agent:queued"}, {:add_label, "2", "agent:queued"}, {:remove_label, "1", "agent:queued"}]
    assert length(result.writer.writes) == 4
    assert Enum.map(result.document.intents, & &1.action) == [:mark, :mark, :unmark]
    Fake.reset(document)
    Fake.put(:ensure_result, {:error, {:github, :local_hold, %{}}})
    failed = run(document, [{:mark, "1"}, {:promote, "2"}])
    assert failed.status == :writes_paused
    assert calls() == [{:ensure_labels, ["agent:queued"]}]
    assert failed.document.intents == []
  end

  defp calls, do: Enum.map(Fake.get(:calls), &elem(&1, 0))
  defp promote(id), do: {:update_issue_state, id, "todo", [expected_state: :none]}

  defp run(document, actions, runtime \\ Writer.new()) do
    Writer.run(
      %{
        document: document,
        tracker: Fake,
        store: Fake,
        claim_probe: Fake,
        clock: &Fake.clock/0,
        sleep: &Fake.sleep/1,
        marker: "agent:queued",
        todo: "agent:todo",
        max_writes: 20,
        observations: input(document).observations
      },
      actions,
      runtime
    )
  end

  defp input(document, opts \\ []) do
    observations = Map.new(document.items, &{&1.issue_id, %Model.Observation{issue_id: &1.issue_id, open?: true, labels: ["agent:queued"], state_reason: nil, pr: nil, observed_at_ms: Fake.clock()}})
    struct!(Planner.Input, Map.to_list(document) ++ [observations: observations, now_ms: Fake.clock(), opts: Keyword.merge([label_prefix: "agent", observation_max_age_ms: 120_000], opts)])
  end

  defp document(count) do
    queue = %Model.Queue{id: "q-0001", name: "Q", kind: :build_order, root: 1, held: false, generation: 0, created_at: ~U[2026-10-08 00:00:00Z]}
    items = for id <- 1..count, do: %Model.Item{issue_id: to_string(id), queue_id: queue.id, position: id, hold: nil, override: nil, promoted_at: nil, added_at: queue.created_at}
    %{queues: [queue], items: items, edges: [], intents: [], latches: []}
  end
end
