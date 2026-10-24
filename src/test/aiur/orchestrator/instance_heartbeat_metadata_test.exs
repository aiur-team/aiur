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
        public_url_fun: fn -> "https://aiur.example" end
      )

    assert %{
             "version" => 1,
             "data" => %{
               "host_kind" => "container",
               "public_url" => "https://aiur.example",
               "agent_count" => 1,
               "agent_capacity" => 3,
               "held_tickets" => ["acme/widgets#42"],
               "leader" => nil,
               "agents" => [%{"identifier" => "acme/widgets#42", "title" => "Roster ticket", "state" => "running"}]
             }
           } = metadata
  end
end
