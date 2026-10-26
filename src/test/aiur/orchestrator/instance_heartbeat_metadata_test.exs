defmodule Aiur.Orchestrator.InstanceHeartbeatMetadataTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.InstanceHeartbeatMetadata

  test "heartbeat publishes per-instance ticket rows and capacity" do
    metadata =
      InstanceHeartbeatMetadata.metadata(
        statuses_fun: fn ->
          [
            %{identifier: "acme/widgets#42", title: "Roster ticket", state: :running},
            %{identifier: "acme/widgets#43", title: "Idle ticket", state: :idle}
          ]
        end,
        capacity_fun: fn -> 3 end,
        held_tickets_fun: fn -> ["acme/widgets#42"] end,
        host_kind_fun: fn -> "container" end,
        public_url_fun: fn -> "https://aiur.example" end,
        ownership_metadata_fun: fn ->
          %{
            "version" => 1,
            "data" => %{
              "owns" => [%{"ticket" => 42}],
              "pool" => false,
              "dispatching" => false
            }
          }
        end
      )

    assert %{
             "version" => 1,
             "data" => %{
               "host_kind" => "container",
               "public_url" => "https://aiur.example",
               "agent_count" => 1,
               "agent_capacity" => 3,
               "held_tickets" => ["acme/widgets#42"],
               "owns" => [%{"ticket" => 42}],
               "pool" => false,
               "dispatching" => false,
               "agents" => [%{"identifier" => "acme/widgets#42", "title" => "Roster ticket", "state" => "running"}]
             }
           } = metadata
  end

  test "roster metadata preserves ownership, pool, and paused state for dispatch" do
    current = metadata_with_ownership(%{"owns" => [], "pool" => true, "dispatching" => true})

    reserved =
      metadata_with_ownership(%{
        "owns" => [%{"ticket" => 42}],
        "pool" => true,
        "dispatching" => true
      })

    assert {:ineligible, :peer_owns_ticket} =
             Aiur.Instance.eligible?(42, "home-a", [
               %{instance_id: "home-a", metadata: current},
               %{instance_id: "container-b", metadata: reserved}
             ])

    pool_closed = metadata_with_ownership(%{"owns" => [], "pool" => false, "dispatching" => true})

    assert {:ineligible, :pool_closed} =
             Aiur.Instance.eligible?(43, "home-a", [
               %{instance_id: "home-a", metadata: pool_closed}
             ])

    paused = metadata_with_ownership(%{"owns" => [], "pool" => true, "dispatching" => false})

    assert {:unavailable, :self_not_dispatching} =
             Aiur.Instance.eligible?(43, "home-a", [
               %{instance_id: "home-a", metadata: paused}
             ])
  end

  defp metadata_with_ownership(data) do
    InstanceHeartbeatMetadata.metadata(
      statuses_fun: fn -> [] end,
      capacity_fun: fn -> 1 end,
      held_tickets_fun: fn -> [] end,
      host_kind_fun: fn -> "home" end,
      public_url_fun: fn -> nil end,
      ownership_metadata_fun: fn -> %{"version" => 1, "data" => data} end
    )
  end
end
