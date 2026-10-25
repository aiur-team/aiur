defmodule Aiur.BuildQueue.SetRankTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildQueue.{ListMutations, Model}
  alias Aiur.BuildQueue.Model.Queue

  test "old store files acquire ranks in creation order with file order breaking ties" do
    queues = [queue("q-0003", ~U[2026-10-11 02:00:00Z]), queue("q-0001", ~U[2026-10-11 01:00:00Z]), queue("q-0002", ~U[2026-10-11 01:00:00Z])]
    old = document(queues) |> Model.encode() |> Map.update!("queues", &Enum.map(&1, fn q -> Map.delete(q, "rank") end))
    assert {:ok, loaded} = Model.decode(old)
    assert Enum.map(loaded.queues, &{&1.id, &1.rank}) == [{"q-0003", 2}, {"q-0001", 0}, {"q-0002", 1}]
  end

  test "stored rank survives JSON and new list queues append after the largest rank" do
    original = document([%{queue("q-0001", ~U[2026-10-11 01:00:00Z]) | rank: 7}])
    assert {:ok, ^original} = original |> Model.encode() |> Jason.encode!() |> Jason.decode!() |> Model.decode()
    assert {:ok, added, _} = ListMutations.add(original, ["42"], [queue: "second"], DateTime.utc_now())
    assert Enum.map(added.queues, & &1.rank) == [7, 8]
    invalid = put_in(Model.encode(original), ["queues", Access.at(0), "rank"], -1)
    assert Model.decode(invalid) == {:error, {:invalid, ["queues", 0, "rank"]}}
  end

  defp queue(id, time), do: %Queue{id: id, name: id, kind: :list, root: nil, held: false, generation: 0, created_at: time}
  defp document(queues), do: %{queues: queues, items: [], edges: [], intents: [], latches: []}
end
