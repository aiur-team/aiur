defmodule AiurWeb.Build.DegradedFixtureTest do
  use Aiur.TestSupport
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias AiurWeb.Build.Payload

  test "degraded snapshot keeps failed reads distinct from empty data" do
    assert {:ok, data} = FixtureSource.snapshot(dataset: "degraded")
    assert :ok = Payload.validate(data)
    assert data["sections"]["hist"] == []
    assert data["sections"]["plan"] == []
    assert data["history"]["total"] == 0
    assert data["history"]["more"] == false
    assert data["sources"]["history"] == %{"state" => "unavailable", "observed_at" => data["now"] - 720_000, "reason" => "timeout"}
    assert data["sources"]["queue"]["state"] == "disabled"
    assert data["sources"]["index"]["observed_at"] == data["now"] - 10_800_000
    assert data["sources"]["index"]["state"] == "stale"
  end
end
