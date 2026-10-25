defmodule Aiur.Test.BuildHome.QueueReadModelFixture do
  @moduledoc false
  @spec item(pos_integer(), keyword()) :: map()
  def item(n, opts \\ []), do: Map.merge(%{number: n, state: :waiting, verdict: :waiting, prerequisites: [], promoted_at: nil}, Map.new(opts))
  @spec queue([map()], keyword()) :: map()
  def queue(items, opts \\ []), do: Map.merge(%{queue_id: "list:test", name: "Test", held: false, items: items}, Map.new(opts))
  @spec show([map()], keyword()) :: map()
  def show(items, opts \\ []),
    do: Map.merge(%{status: :running, queues: [queue(items)], sources: %{tracker: %{freshness: :current, observed_at: ~U[2026-10-08 00:00:00Z], reasons: []}}}, Map.new(opts))

  @spec edge(pos_integer(), atom()) :: map()
  def edge(n, verdict \\ :pending), do: %{number: n, verdict: verdict}
  @spec live() :: {map(), map(), MapSet.t()}
  def live do
    fixture = "test/fixtures/build_home/live.json" |> File.read!() |> Jason.decode!()
    data = fixture["sections"]
    done = MapSet.new(for row <- data["hist"], row["status"] == "done", do: row["num"])
    items = Enum.map(data["plan"], &design_item(&1, done))
    {show(items), fixture, MapSet.new(data["now"], & &1["num"])}
  end

  defp design_item(row, done) do
    deps =
      Enum.map(row["deps"], fn id ->
        n = id |> String.replace_prefix("AIUR-", "") |> String.to_integer()
        edge(n, if(MapSet.member?(done, n), do: :satisfied, else: :pending))
      end)

    cond do
      row["cue"]["held"] -> item(row["num"], prerequisites: deps, state: :held, hold_by: "Maya", hold_reason: "release freeze until Thu")
      row["cue"]["promoted"] -> item(row["num"], prerequisites: deps, state: :promoted, promoted_at: DateTime.from_unix!(row["cue"]["promoted"], :millisecond))
      true -> item(row["num"], prerequisites: deps)
    end
  end
end
