defmodule Aiur.DecisionValidationTicketIdentityTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionValidation.TicketIdentity

  test "rehydrates a joinable tracker identity from the durable JSON ticket map" do
    ticket = %{identifier: "979"}

    persisted_identity = %{
      "version" => 1,
      "status" => "joinable",
      "kind" => "github",
      "owner" => "aiur-team",
      "repository" => "aiur",
      "provider_id" => "issue-node-979",
      "database_id" => 979,
      "identifier" => "979",
      "reason" => nil
    }

    assert %{tracker_identity: %Aiur.TrackerIdentity{status: :joinable, kind: :github, provider_id: "issue-node-979"}} =
             TicketIdentity.put(ticket, persisted_identity)
  end

  test "does not retain unjoinable identities" do
    assert %{identifier: "979"} =
             TicketIdentity.put(%{identifier: "979"}, %Aiur.TrackerIdentity{status: :unjoinable})
  end
end
