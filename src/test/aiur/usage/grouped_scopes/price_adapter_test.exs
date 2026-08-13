defmodule Aiur.Usage.GroupedScopes.PriceAdapterTest do
  use ExUnit.Case, async: true

  alias Aiur.Usage.GroupedScopes.PriceAdapter
  alias Aiur.Usage.PriceTable
  alias Aiur.UsageEnvelope.RelationshipRegistry

  test "registry providers without aggregate relationships return coverage instead of crashing" do
    {:ok, relationships} = RelationshipRegistry.new()
    {:ok, prices} = PriceTable.default()

    dims = %{
      provider: :fake,
      relationship_revision: "fake-app-server-1",
      resolved_model: "fake-1",
      pricing_date: ~D[2026-07-31]
    }

    assert {:unknown, :missing_historic_relationship_revision} =
             PriceAdapter.price(dims, :input, %{input: 1}, relationships, "USD", prices)
  end
end
