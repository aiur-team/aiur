defmodule Aiur.InstanceSummary.FactTest do
  use ExUnit.Case, async: true

  alias Aiur.InstanceSummary.Fact

  test "degraded builders never carry a value" do
    for {builder, status} <- [{&Fact.unavailable/1, :unavailable}, {&Fact.disabled/1, :disabled}, {&Fact.unknown/1, :unknown}] do
      fact = builder.("not_running")
      assert fact.status == status
      refute Map.has_key?(fact, :value)
      assert fact.reason == "not_running"
      assert fact.freshness == nil
    end
  end

  test "available zero keeps source observation and freshness" do
    observed = DateTime.utc_now() |> DateTime.to_iso8601()
    assert %{status: :available, value: 0, observed_at: ^observed, age_ms: 42, freshness: :stale, reason: nil} = Fact.available(0, observed, age_ms: 42, freshness: :stale)
  end
end
