defmodule Aiur.Orchestrator.CiLifecycle.TerminalPRTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.Orchestrator.State

  setup :ci_lifecycle_setup

  test "a merged PR moves a still-open ci-wait ticket to rework" do
    identifier = unique_identifier("merged-pr-rework")
    RecordingGitHubClient.record_to(self())
    ticket = issue(identifier, "ci-wait")

    poll_ci(%State{}, ticket, %{decision: :pending, pull_request: %{"number" => 91, "state" => "merged"}})

    assert_received {:tracker_update, ^identifier, "rework", [expected_state: "ci-wait"]}
  end

  test "a closed unmerged PR reports its cause and moves the ticket to rework" do
    identifier = unique_identifier("closed-pr-rework")
    RecordingGitHubClient.record_to(self())
    ticket = issue(identifier, "ci-wait")

    poll_ci(%State{}, ticket, %{decision: :pending, pull_request: %{"number" => 92, "state" => "closed"}})

    assert_received {:tracker_update, ^identifier, "rework", [expected_state: "ci-wait"]}
    assert_received {:tracker_comment, ^identifier, body}
    assert body =~ "pr_closed_unmerged"
  end
end
