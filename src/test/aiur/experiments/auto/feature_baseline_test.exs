defmodule Aiur.Experiments.Auto.FeatureBaselineTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Snapshot

  test "moving the feature before window drops retained samples outside its new bounds" do
    row = fn id, at -> %{"unit_id" => id, "value" => 1, "at" => at, "started_at" => at, "censored" => false} end
    old = %{"revision" => 1, "metrics" => %{"app/jobs" => %{"observations" => [row.("old", "2026-09-26T00:00:00Z"), row.("kept", "2026-10-01T00:00:00Z")]}}}
    spec = %{"id" => "feature-test", "metrics" => [%{"ref" => "app/jobs"}], "design" => %{"assign_by" => "start"}}
    data = %{window: %{"start" => "2026-09-29T00:00:00Z", "end" => "2026-10-13T00:00:00Z"}, metrics: %{"app/jobs" => %{"observations" => [row.("new", "2026-10-12T00:00:00Z")]}}}
    assert {:ok, snapshot} = Snapshot.prepare_spec(spec, "before", old, data, reason: "first merge", max_observations: 100, context: %{catalog: %{packs: %{}}})
    assert Enum.map(snapshot["metrics"]["app/jobs"]["observations"], & &1["unit_id"]) == ["kept", "new"]
    assert snapshot["observation_count"] == 2
  end
end
