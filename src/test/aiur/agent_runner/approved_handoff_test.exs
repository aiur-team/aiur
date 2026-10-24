defmodule Aiur.AgentRunner.ApprovedHandoffTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Events.GithubCIPoller.ApprovalCarry
  alias Aiur.Issue

  @contribution %{"files" => [%{"filename" => "lib/a.ex", "sha" => "blob", "patch" => "@@ -1,1 +1,2 @@\n a\n+b"}]}

  # A merge of main moved the head; the PR's own contribution diff is unchanged.
  defp merge_only_classifier(test_pid) do
    fn approved, head, number, _opts ->
      send(test_pid, {:classified, approved, head, number})
      ApprovalCarry.classify_diffs(@contribution, @contribution, %{"files" => []}, "Tested head: #{head}\n", head)
    end
  end

  defp hand_back(issue, approval, classifier, reviews \\ []) do
    test_pid = self()

    executor =
      ToolExecutor.build(issue, nil, nil, %{},
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ticket_state_writer: fn _issue_id, state -> send(test_pid, {:state_write, state}) && :ok end,
        open_pr_fetcher: fn _ -> {:ok, %{"number" => 77, "head" => %{"sha" => "merged-head"}}} end,
        reviews_fetcher: fn _ -> {:ok, reviews} end,
        pr_issue_comments_fetcher: fn _ -> {:ok, []} end,
        pull_request_approval_fetcher: fn 77 -> approval end,
        approval_carry_classifier: classifier
      )

    executor.("aiur_set_ticket_state", %{"state" => "human-review"})
  end

  test "an approved PR whose approval carries across a merge-only head change hands back to ci-wait" do
    response = hand_back(%Issue{id: "gid", identifier: "4965", state: "in-progress"}, {:ok, {"merged-head", "approved-head"}}, merge_only_classifier(self()))

    assert response["success"]

    assert Jason.decode!(response["output"]) == %{
             "ok" => true,
             "state" => "ci-wait",
             "requested_state" => "human-review",
             "result" => %{
               "state" => "ci-wait",
               "issue" => "gid",
               "requested_state" => "human-review",
               "reason" => "approval_carries_to_pr_head"
             }
           }

    assert_receive {:classified, "approved-head", "merged-head", 77}, 100
    assert_receive {:state_write, "ci-wait"}, 100
  end

  test "an unapproved PR hands back to human-review" do
    response = hand_back(%Issue{id: "gid", identifier: "4965", state: "in-progress"}, {:ok, {"merged-head", nil}}, merge_only_classifier(self()))

    assert response["success"]
    decoded = Jason.decode!(response["output"])
    assert decoded["state"] == "human-review"
    assert decoded["requested_state"] == "human-review"
    refute Map.has_key?(decoded["result"], "reason")
    assert_receive {:state_write, "human-review"}, 100
    refute_received {:classified, _, _, _}
  end

  test "an approval at the remote PR head reports the redirect without classifying local merge drift" do
    classifier = fn _, _, _, _ -> flunk("exact remote approval needs no diff classification") end
    response = hand_back(%Issue{id: "gid", identifier: "5456", state: "ci-wait"}, {:ok, {"merged-head", "merged-head"}}, classifier)

    assert response["success"]
    decoded = Jason.decode!(response["output"])
    assert decoded["state"] == "ci-wait"
    assert decoded["requested_state"] == "human-review"
    assert decoded["result"]["reason"] == "approval_carries_to_pr_head"
    assert_receive {:state_write, "ci-wait"}, 100
  end

  test "an approval that does not carry hands back to human-review" do
    changed = fn _approved, _head, _number, _opts -> {:changed, %{reason: :contribution_changed, hunks: []}} end
    response = hand_back(%Issue{id: "gid", identifier: "4965", state: "in-progress"}, {:ok, {"merged-head", "approved-head"}}, changed)

    assert response["success"]
    assert_receive {:state_write, "human-review"}, 100
  end

  test "a rework handback with a carried approval routes to ci-wait" do
    response = hand_back(%Issue{id: "gid", identifier: "4965", state: "rework"}, {:ok, {"merged-head", "approved-head"}}, merge_only_classifier(self()))

    assert response["success"]
    assert_receive {:state_write, "ci-wait"}, 100
  end

  test "an accepted body-only rework handback stays in human-review despite the blocking review" do
    review = %{"state" => "CHANGES_REQUESTED", "commit_id" => "merged-head", "submitted_at" => "2026-10-18T00:00:00Z", "user" => %{"login" => "reviewer"}, authoritative: true}
    response = hand_back(%Issue{id: "gid", identifier: "4965", state: "in-progress"}, {:ok, {"merged-head", "merged-head"}}, merge_only_classifier(self()), [review])

    assert response["success"]
    assert_receive {:state_write, "human-review"}, 100
  end
end
