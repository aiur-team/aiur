defmodule Aiur.Experiments.Packs.DeliverySpeedAccountingTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Packs.DeliverySpeed
  alias Aiur.TrackerIdentity

  test "one scoped query and snapshot provide distinct costs for multiple merged tickets" do
    repo = {"fixture", "repo"}

    identities =
      Enum.map([101, 102], fn n ->
        {:ok, identity} = TrackerIdentity.from_github(%{"number" => n, "node_id" => "I_#{n}"}, repo, repo)
        identity
      end)

    [first, second] = identities

    groups =
      Map.new([{first, "1.20"}, {second, "0.80"}], fn {identity, usd} ->
        {TrackerIdentity.github_key(identity), %{money: %{{:provider_reported_estimate, "USD"} => Decimal.new(usd)}, tokens: %{}}}
      end)

    ctx = %{
      telemetry_enabled: true,
      boot_id: "boot-b",
      telemetry_path: Enum.map(["boot-a.ndjson", "boot-b.ndjson"], &Path.expand("../../../fixtures/experiments/telemetry/" <> &1, __DIR__)),
      prior_loader: fn _ -> {[], false} end,
      identity_lookup: fn _ -> {:ok, Enum.map(identities, &%{identifier: &1.identifier, tracker_identity: &1})} end,
      usage_query: fn %{tickets: scoped} ->
        assert MapSet.new(scoped) == MapSet.new(identities)
        send(self(), :usage_queried)
        %{health: :healthy, freshness: %{status: :fresh}, aggregate_generation: 7, coverage: %{projection: %{partial_records: 0}}, groups: %{by_ticket: groups}}
      end,
      usage_snapshot: fn ->
        send(self(), :snapshot_read)
        %{metadata: %{generation: 7}, cells: %{}}
      end
    }

    window = %{start: ~U[2026-10-09 09:00:00Z], end: ~U[2026-10-09 14:00:00Z]}
    {_coverage, observations} = DeliverySpeed.observations(["spend_per_merged_ticket"], window, ctx)["spend_per_merged_ticket"]
    assert Map.new(observations, &{&1.unit_id, &1.value}) == %{"ticket:101" => 1.2, "ticket:102" => 0.8}
    assert_received :usage_queried
    refute_received :usage_queried
    assert_received :snapshot_read
    refute_received :snapshot_read
  end
end
