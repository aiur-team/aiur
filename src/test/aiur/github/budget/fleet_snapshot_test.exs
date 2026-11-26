defmodule Aiur.GitHub.Budget.FleetSnapshotTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Budget.FleetSnapshot

  test "sums only daemon-attributed points by shared GitHub resource" do
    snapshots = [
      %{snapshot: %{callers: [%{resource: "core", points: 12}, %{resource: "graphql", points: 60}]}},
      %{snapshot: %{callers: [%{resource: "core", points: 8}, %{resource: "search", points: 3}, %{resource: "external", points: 90}]}}
    ]

    assert FleetSnapshot.summarize(snapshots) == %{"core" => 20, "graphql" => 60, "search" => 3}
  end

  test "status explains observed, missing and host-local shared budget state" do
    observed = %{state: :observed, resources: %{"core" => 20, "graphql" => 60}, observed_instances: 2, age_seconds: 8}

    assert FleetSnapshot.status_line(true, observed) =~ "core=20 requests graphql=60 points instances=2 observed=8s"
    assert FleetSnapshot.status_line(true, %{state: :unknown}) =~ "has no fleet sample yet"
    assert FleetSnapshot.status_line(false, %{state: :unknown}) =~ "host-local"
    assert FleetSnapshot.status_line(true, observed) =~ "agent gh calls are counted per host"
  end
end
