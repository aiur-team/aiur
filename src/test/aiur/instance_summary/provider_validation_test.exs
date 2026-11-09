defmodule Aiur.InstanceSummary.ProviderValidationTest do
  use ExUnit.Case, async: true

  alias Aiur.InstanceSummary
  alias Aiur.InstanceSummary.Fact

  test "malformed provider facts become value-free unknown facts" do
    valid = Fact.available(0, DateTime.to_iso8601(DateTime.utc_now()))

    malformed =
      [
        0,
        nil,
        %{},
        %{value: 0},
        %{valid | status: :bogus},
        %{valid | status: "available"},
        Map.delete(%{valid | status: :bogus}, :value),
        Map.delete(%{valid | status: "available"}, :value),
        %{valid | observed_at: nil},
        %{valid | observed_at: "not_a_timestamp"},
        %{valid | age_ms: -1},
        %{valid | age_ms: 1.5},
        %{valid | freshness: :bogus},
        %{valid | reason: 42},
        %{valid | status: :unknown},
        Map.delete(valid, :value)
      ] ++ Enum.map([:status, :observed_at, :age_ms, :freshness, :reason], &Map.delete(valid, &1))

    for bad <- malformed do
      result = InstanceSummary.v1(instance_id: fn -> nil end, providers: %{active: fn -> bad end})
      assert result.agents.active.status == :unknown
      assert result.agents.active.reason == "provider_failed"
      refute Map.has_key?(result.agents.active, :value)
    end
  end
end
