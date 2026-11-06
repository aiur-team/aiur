defmodule Aiur.BuildOrder.PublishedGoldenTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.Published
  alias Aiur.BuildOrder.PublishedReference

  # The golden document lives beside the contract fixtures so
  # `npm run check` in packages/aiur-contracts validates the encoder's own
  # output against build-order.v1. Regenerate with AIUR_UPDATE_GOLDEN=1.
  @golden Path.expand("../../../../packages/aiur-contracts/fixtures/build-order.golden.v1.json", __DIR__)
  @edge_kinds ~w(depends_on serializes_with suggested_after contains gates)

  test "the encoder's reference document matches the committed golden document" do
    document = Published.encode(PublishedReference.selected_snapshot(), PublishedReference.encode_opts())

    if System.get_env("AIUR_UPDATE_GOLDEN") in ["1", "true"] do
      File.write!(@golden, Jason.encode!(ordered(document), pretty: true) <> "\n")
    end

    assert File.exists?(@golden), "missing golden document at #{@golden}; run AIUR_UPDATE_GOLDEN=1"

    committed = @golden |> File.read!() |> Jason.decode!()

    assert committed == document,
           "build-order.v1 golden document is stale; regenerate with AIUR_UPDATE_GOLDEN=1"
  end

  test "the golden document publishes every typed edge kind and an honest source" do
    committed = @golden |> File.read!() |> Jason.decode!()

    assert committed["contract"] == "aiur.build_order"
    assert committed["contract_version"] == 1

    kinds = committed["edges"] |> Enum.map(& &1["kind"]) |> Enum.uniq() |> Enum.sort()
    assert kinds == Enum.sort(@edge_kinds)

    for source <- ["pack", "tracker", "progress"] do
      assert committed["sources"][source]["status"] in ["known", "stale", "unknown"]
    end
  end

  # A stable key order keeps the committed document diffable across OTP
  # versions; JSON object order carries no meaning for the contract.
  defp ordered(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, child} -> {to_string(key), ordered(child)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value
end
