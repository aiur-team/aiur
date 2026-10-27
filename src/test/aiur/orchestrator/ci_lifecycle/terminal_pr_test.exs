defmodule Aiur.Orchestrator.CiLifecycle.TerminalPRTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.Events.GithubCIPoller
  alias Aiur.GitHub.{CIPollBatch, CIPollBatchTestSupport}
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.PrLessReview
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

  test "the batch poller carries a non-closing merged PR into ci-wait rework" do
    identifier = "42"
    RecordingGitHubClient.record_to(self())
    ticket = issue(identifier, "ci-wait")
    result = terminal_poll_result(ticket, :merged, false)

    next = poll_ci(%State{}, ticket, result)

    assert_received {:tracker_update, ^identifier, "rework", [expected_state: "ci-wait"]}
    assert_received {:tracker_comment, ^identifier, _body}

    poll_ci(next, %{ticket | state: "rework", state_labels: ["rework"]}, result)

    refute_received {:tracker_update, ^identifier, _state, _opts}
    refute_received {:tracker_comment, ^identifier, _body}
  end

  test "the batch poller reports a closed unmerged PR and leaves the ticket in rework" do
    identifier = "42"
    RecordingGitHubClient.record_to(self())
    ticket = issue(identifier, "ci-wait")
    result = terminal_poll_result(ticket, :closed, false)

    poll_ci(%State{}, ticket, result)

    assert_received {:tracker_update, ^identifier, "rework", [expected_state: "ci-wait"]}
    assert_received {:tracker_comment, ^identifier, body}
    assert body =~ "pr_closed_unmerged"
  end

  test "a closing merged PR on a closed ci-wait issue is repaired to done without rework or comment" do
    identifier = "42"
    RecordingGitHubClient.record_to(self())
    ticket = %{issue(identifier, "Closed") | state_labels: ["ci-wait"], labels: ["agent:ci-wait"]}
    result = terminal_poll_result(ticket, :merged, true)

    poll_ci(%State{}, ticket, result)

    assert_received {:tracker_update, ^identifier, "done", [expected_state: "Closed"]}
    refute_received {:tracker_update, ^identifier, "rework", _opts}
    refute_received {:tracker_comment, ^identifier, _body}
  end

  test "a terminal PR poll does not churn a human-review ticket back to ci-wait" do
    identifier = "42"
    ticket = issue(identifier, "human-review")
    batch = terminal_poll_batch(ticket, :merged, false)
    state = running_state(ticket, self(), :working, [])
    parent = self()

    next =
      Enum.reduce(1..3, state, fn _, acc ->
        CiLifecycle.poll_github_ci(%{acc | last_ci_poll_started_at_ms: nil},
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [ticket]} end,
          ci_batch: batch,
          ci_poller: fn [^identifier], opts ->
            {:ok, %{results: [result], errors: []}} = GithubCIPoller.poll([identifier], opts)
            send(parent, {:terminal_result, result})
            {:ok, %{results: [result], errors: []}}
          end,
          required_check_fetcher: fn _opts -> {:ok, []} end,
          request_fun: fn _request -> flunk("terminal PRs must skip base repair and CI evaluation") end,
          parked_ready_alert_loader: fn -> MapSet.new() end,
          draft_stall_alert_loader: fn -> MapSet.new() end
        )
      end)

    assert_received {:terminal_result, result}
    assert result.pending_reason == :pr_merged
    assert PrLessReview.no_pull_request?(result)
    refute_received {:tracker_update, ^identifier, _state, _opts}
    assert next.running[identifier].issue.state == "human-review"
  end

  defp terminal_poll_result(ticket, state, closes_ticket?) do
    batch = terminal_poll_batch(ticket, state, closes_ticket?)

    assert {:ok, %{results: [result], errors: []}} =
             GithubCIPoller.poll([ticket.identifier],
               ci_batch: batch,
               base_branch: "main",
               required_check_fetcher: fn _opts -> {:ok, []} end,
               request_fun: fn _request -> flunk("terminal PRs must skip base repair and CI evaluation") end
             )

    assert result.decision == :pending
    assert result.pending_reason == if(state == :merged, do: :pr_merged, else: :pr_closed_unmerged)
    assert result.pull_request["state"] == if(state == :merged, do: "merged", else: "closed")
    result
  end

  defp terminal_poll_batch(ticket, state, closes_ticket?) do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    try do
      node =
        CIPollBatchTestSupport.pull_request()
        |> Map.put("number", String.to_integer(ticket.identifier))
        |> Map.put("state", "CLOSED")
        |> Map.put("mergedAt", if(state == :merged, do: "2026-10-20T00:00:00Z", else: nil))
        |> Map.put("baseRefName", "develop")
        |> Map.put("closingIssuesReferences", %{
          "nodes" => if(closes_ticket?, do: [%{"number" => String.to_integer(ticket.identifier)}], else: []),
          "pageInfo" => %{"hasNextPage" => false}
        })

      assert {:ok, batch} =
               CIPollBatch.fetch([ticket.identifier],
                 request_fun: fn %{body: body} ->
                   assert body["query"] =~ "closingIssuesReferences(first: 100)"
                   CIPollBatchTestSupport.ci_response(node)
                 end,
                 branch_names_by_target: %{ticket.identifier => "aiur/#{ticket.identifier}-ci-batch"}
               )

      batch
    after
      restore_env("GITHUB_TOKEN", previous_token)
    end
  end
end
