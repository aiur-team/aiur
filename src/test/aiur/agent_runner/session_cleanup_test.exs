defmodule Aiur.AgentRunner.SessionCleanupTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.SessionCleanup
  alias Aiur.Claude.Telemetry
  alias Aiur.Issue
  alias Aiur.TrackerIdentity

  test "cleanup revokes the prepared launch telemetry generation" do
    baseline = Telemetry.health().active_generations

    {:ok, tracker_identity} =
      TrackerIdentity.from_github(
        %{"node_id" => "I_kwDOCleanup", "number" => 5182},
        {"owner", "repo"},
        {"owner", "repo"}
      )

    issue = %Issue{id: "5182", identifier: "5182", tracker_identity: tracker_identity}

    assert {:ok, launch} =
             Telemetry.prepare_launch(issue,
               backend: "claude",
               attempt_id: "cleanup-test",
               workspace_ownership: %{generation: System.unique_integer([:positive])}
             )

    on_exit(fn -> Telemetry.revoke(launch) end)
    assert Telemetry.health().active_generations == baseline + 1

    assert :ok = SessionCleanup.stop(%{backend: "claude", telemetry_launch: launch}, nil, fn _session -> :ok end)

    assert Telemetry.health().active_generations == baseline
  end
end
