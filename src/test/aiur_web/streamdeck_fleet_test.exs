defmodule AiurWeb.StreamdeckFleetTest do
  use ExUnit.Case, async: true
  alias AiurWeb.StreamdeckFleet

  test "a current published snapshot wins over retained running summaries" do
    snapshot = %{agents: [%{identifier: "3875", title: "published"}]}
    summaries = [%{identifier: "3875", title: "older running update"}]

    for current <- [snapshot, {:current, snapshot, %{status: :current, age_ms: 0}}] do
      assert %{"agents" => [%{"title" => "published"}]} = StreamdeckFleet.with_grid(current, summaries)
    end
  end

  test "stale or unavailable snapshots fall back to current running summaries" do
    snapshot = %{agents: [%{identifier: "3875", title: "retained"}]}
    summaries = [%{identifier: "3875", title: "running now"}]

    for unavailable <- [{:stale, snapshot, %{status: :stale}}, :unavailable] do
      assert %{"agents" => [%{"title" => "running now"}]} = StreamdeckFleet.with_grid(unavailable, summaries)
    end

    assert %{"agents" => [%{"title" => "retained"}]} = StreamdeckFleet.with_grid({:stale, snapshot, %{}}, nil)
  end

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
