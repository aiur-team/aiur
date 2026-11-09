defmodule Aiur.BuildOrder.FeatureOldestTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.Index
  alias AiurWeb.Build.Payload

  test "oldest includes also-affects closures across the whole index, never feature start" do
    earlier = DateTime.from_unix!(now() - 172_800_000, :millisecond)
    p = parts([row(1), row(2, %{end: earlier}), row(3, %{end: :unknown}), row(4, %{end: DateTime.from_unix!(now() - 86_400_000, :millisecond)})])
    f = %{slug: "focus", label: "Focus", hue: 42, epics: [], from: DateTime.from_unix!(now() - 604_800_000, :millisecond), to: :none, baseline: :none}

    registry = %{
      features: %{"focus" => f, "empty" => %{f | slug: "empty"}},
      owners: %{1 => %{feature: "focus", epic: nil, joined_at: earlier}},
      also: %{2 => ["focus"], 3 => ["empty"]},
      health: health()
    }

    assert {:ok, index} = assemble(Map.put(p, :features, {:ok, registry}))
    assert index.features["focus"].oldest == now() - 172_800_000
    assert index.features["empty"].oldest == nil
    refute index.features["focus"].oldest == index.features["focus"].from
    page = index |> Index.base() |> Index.window("Etc/UTC", now())
    assert page.features["focus"].oldest == now() - 172_800_000
    assert Enum.all?(page.sections.hist, &(&1.num != 2))
  end

  test "payload validates nullable oldest and rejects an invented timestamp" do
    payload = Path.expand("../../fixtures/build_home/live.json", __DIR__) |> File.read!() |> Jason.decode!()
    assert :ok = Payload.validate(payload)
    assert :ok = Payload.validate(put_in(payload, ["features", "khala", "oldest"], nil))
    assert {:error, _reason} = Payload.validate(put_in(payload, ["features", "khala", "oldest"], "yesterday"))
    assert {:error, _reason} = Payload.validate(put_in(payload, ["features", "khala", "oldest"], 1.5))
  end
end
