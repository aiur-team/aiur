defmodule AiurWeb.Build.TimingPayloadTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.History.{Row, Timing}
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias AiurWeb.Build.Payload

  test "unknown start reaches snapshot, diff and earlier contracts with its source" do
    {:ok, data} = FixtureSource.full(dataset: "live")
    base = hd(data["sections"]["hist"])
    timing = Timing.derive(nil, %Row{closed_at: DateTime.from_unix!(base["end"], :millisecond)}) |> Timing.to_payload()
    row = Map.merge(base, Map.new(timing, fn {key, value} -> {Atom.to_string(key), value} end))
    data = put_in(data, ["sections", "hist"], [row])

    for message <- [
          Payload.snapshot(data, "E", 0),
          Payload.diff(%{now: data["now"], upsert: [row], remove: [], set: %{}}, "E", 1, nil),
          Payload.earlier(%{"rows" => [row], "history" => data["history"]}, "E", 2)
        ] do
      assert Payload.validate(message) == :ok
    end

    assert Map.take(row, ~w(start start_src)) == %{"start" => nil, "start_src" => "unknown"}
    bad = put_in(data, ["sections", "hist", Access.at(0), "start_src"], "label")
    assert {:error, errors} = Payload.validate(Payload.snapshot(bad, "E", 0))
    assert {"sections.hist.0.start_src", :timing} in errors
    assert {:ok, _} = Payload.row(row)
  end
end
