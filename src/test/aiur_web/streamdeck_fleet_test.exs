defmodule AiurWeb.StreamdeckFleetTest do
  use ExUnit.Case, async: true
  alias AiurWeb.StreamdeckFleet

  test "production snapshot rows preserve model metadata and share the grid's fleet and freshness" do
    snapshot = %{
      running: [%{identifier: "3875", title: "worker", requested_model: "gpt-5.5", backend: "codex", work_state: :working}],
      retrying: [],
      idle: []
    }

    freshness = %{status: :stale, age_ms: 90_000, reason: :snapshot_timeout}
    retained = {:stale, snapshot, freshness}
    assert %{"agents" => [%{"identifier" => "3875", "model" => "gpt-5.5", "status" => "running"}]} = StreamdeckFleet.fleet(retained)
    grid = StreamdeckFleet.grid(retained)
    assert [%{identifier: "3875", title: "worker", bucket: :running}] = grid.agents
    assert grid.snapshot_freshness == freshness
  end
end
