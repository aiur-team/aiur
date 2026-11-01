defmodule Aiur.GitHub.CIPollBatchReadyReviewTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{AgentMarker, CIPollBatchReadyReview}
  alias Aiur.Workflow

  test "only approved or changes-requested reviews on the head count as reviewed" do
    head = "review-head"
    base = %{"headRefOid" => head}

    for state <- ["COMMENTED", "PENDING"] do
      node = Map.put(base, "reviews", %{"nodes" => [%{"state" => state, "commit" => %{"oid" => head}}]})
      assert CIPollBatchReadyReview.project(node).reviewed_head? == false
    end

    for state <- ["APPROVED", "CHANGES_REQUESTED"] do
      node = Map.put(base, "reviews", %{"nodes" => [%{"state" => state, "commit" => %{"oid" => head}}]})
      assert CIPollBatchReadyReview.project(node).reviewed_head? == true
    end
  end

  test "single-account mode ignores agent-marked reviews at the head" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_identity_mode: "single_account")
    on_exit(fn -> write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_identity_mode: "separate_account") end)

    head = "review-head"
    review = %{"state" => "APPROVED", "body" => "review\n\n" <> AgentMarker.marker(), "commit" => %{"oid" => head}}
    node = %{"headRefOid" => head, "reviews" => %{"nodes" => [review]}}

    assert CIPollBatchReadyReview.project(node).reviewed_head? == false
  end
end
