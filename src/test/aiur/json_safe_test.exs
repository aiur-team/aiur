defmodule Aiur.JSONSafeTest do
  use ExUnit.Case, async: true

  alias Aiur.{JSONSafe, TrackerIdentity}

  test "normalizes structs without exposing their implementation tag" do
    identity = %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "aiur-team",
      repository: "aiur",
      provider_id: "node-1594",
      identifier: "1594",
      reason: nil
    }

    assert JSONSafe.normalize(identity) == %{
             "database_id" => nil,
             "identifier" => "1594",
             "kind" => "github",
             "owner" => "aiur-team",
             "provider_id" => "node-1594",
             "reason" => nil,
             "repository" => "aiur",
             "status" => "joinable",
             "version" => 1
           }
  end
end
