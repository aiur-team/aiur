defmodule Aiur.BuildQueue.ExecutorListTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildQueue.{ListMutations, Model, Planner}
  alias Aiur.BuildQueue.Sources.ExecutorList

  @now ~U[2026-10-08 00:00:00Z]
  @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

  test "add twice to different queues is refused with the owner's name" do
    {:ok, doc, [{:mark, "1"}]} = add(@empty, ["1"])
    assert {:error, {:already_queued, "paseo"}} = add(doc, ["2", "1"], queue: "other")
  end

  test "after creates list edges and the planner keeps the dependent waiting" do
    {:ok, doc, [{:mark, "2"}]} = add(@empty, ["2"], after: "1")
    [queue] = doc.queues
    assert {:ok, [item], [%Model.Edge{prerequisite: "1", dependent: "2", source: :list}], :current} = ExecutorList.members(queue, doc)
    assert item.issue_id == "2"
    input = struct!(Planner.Input, Map.to_list(doc) ++ [observations: Map.new(["1", "2"], &{&1, observation(&1)}), now_ms: 1_000, opts: opts()])
    assert {[%{issue_id: "2", state: :waiting}], actions} = Planner.plan(input)
    refute {:promote, "2"} in actions
  end

  test "insertion, reorder and removal renumber positions densely" do
    {:ok, doc, [{:mark, "1"}, {:mark, "3"}]} = add(@empty, ["1", "3"])
    {:ok, doc, _} = add(doc, ["2"], at: 1)
    assert positions(doc) == [{"1", 0}, {"2", 1}, {"3", 2}]
    assert {:ok, doc, []} = ListMutations.reorder(doc, "3", 0)
    assert positions(doc) == [{"3", 0}, {"1", 1}, {"2", 2}]
    assert {:ok, doc, [{:unmark, "1"}]} = ListMutations.remove(doc, "1")
    assert positions(doc) == [{"3", 0}, {"2", 1}]
  end

  test "self edges refused on add and add_edge; cycles remain visible as unknown" do
    assert {:error, :self_edge} = add(@empty, ["1"], after: "1")
    {:ok, doc, _} = add(@empty, ["1", "2"])
    assert {:error, :self_edge} = ListMutations.add_edge(doc, "1", "1")
    assert {:error, :invalid_ids} = ListMutations.add_edge(doc, nil, "1")
    {:ok, doc, []} = ListMutations.add_edge(doc, "1", "2")
    {:ok, doc, []} = ListMutations.add_edge(doc, "2", "1")
    input = struct!(Planner.Input, Map.to_list(doc) ++ [now_ms: 1_000, opts: opts()])
    {states, _} = Planner.plan(input)
    assert Enum.map(states, &{&1.issue_id, &1.state, &1.verdict}) == [{"1", :unknown, {:unknown, [:cyclic]}}, {"2", :unknown, {:unknown, [:cyclic]}}]
  end

  test "remove deletes incoming list edges but preserves prerequisites of remaining members" do
    {:ok, doc, _} = add(@empty, ["1"], after: "9")
    {:ok, doc, _} = add(doc, ["2"], after: "1")
    {:ok, doc, _} = ListMutations.remove(doc, "1")
    assert doc.edges == [%Model.Edge{prerequisite: "1", dependent: "2", source: :list}]
  end

  test "source isolates queues and sorts local items; codec accepts output" do
    {:ok, doc, _} = add(@empty, ["1", "2"])
    {:ok, doc, _} = add(doc, ["3"], queue: "other", after: "8")
    [queue | _] = doc.queues
    assert {:ok, items, [], :current} = ExecutorList.members(queue, %{doc | items: Enum.reverse(doc.items)})
    assert Enum.map(items, & &1.issue_id) == ["1", "2"]
    assert {:ok, ^doc} = doc |> Model.encode() |> Jason.encode!() |> Jason.decode!() |> Model.decode()
    build_order = %{queue | kind: :build_order, root: 1}
    assert {:unavailable, :not_list} = ExecutorList.members(build_order, doc)
    build_doc = %{doc | queues: [build_order | tl(doc.queues)]}
    assert {:error, :not_list} = ListMutations.remove(build_doc, "1")
    assert {:error, :not_list} = add(build_doc, ["4"])
  end

  test "invalid batches and positions are refused" do
    assert {:error, :invalid_ids} = add(@empty, ["1", "1"])
    assert {:error, :invalid_ids} = add(@empty, ["0"])
    assert {:error, :invalid_ids} = add(@empty, ["1\n"])
    assert {:error, :invalid_queue} = add(@empty, ["1"], queue: " ")
    assert {:error, :invalid_position} = add(@empty, ["1"], at: 1)
    {:ok, doc, _} = add(@empty, ["1", "2"])
    assert {:error, :invalid_position} = ListMutations.reorder(doc, "2", 2)
    assert {:error, :invalid_position} = ListMutations.reorder(doc, "1", -1)
  end

  defp add(doc, ids, options \\ []), do: ListMutations.add(doc, ids, Keyword.merge([queue: "paseo"], options), @now)
  defp positions(doc), do: Enum.map(doc.items, &{&1.issue_id, &1.position})
  defp opts, do: [label_prefix: "agent", observation_max_age_ms: 10_000]
  defp observation(id), do: %Model.Observation{issue_id: id, open?: true, labels: ["agent:queued"], state_reason: nil, pr: nil, observed_at_ms: 1_000}
end
