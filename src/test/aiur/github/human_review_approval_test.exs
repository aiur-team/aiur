defmodule Aiur.GitHub.HumanReviewApprovalTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{HumanReviewGate, ResourceStore}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()
    on_exit(fn -> ResourceStore.reset() end)
    :ok
  end

  test "uses each reviewer's latest verdict and ignores later comments" do
    reviews = [
      review("owner", "APPROVED", "2026-08-10T11:00:00Z"),
      review("owner", "CHANGES_REQUESTED", "2026-08-10T10:00:00Z"),
      review("owner", "COMMENTED", "2026-08-10T12:00:00Z")
    ]

    assert {:ok, true} = approval(reviews)
  end

  test "a different reviewer's standing request for changes blocks approval" do
    assert {:ok, false} = approval([review("owner", "APPROVED"), review("other", "CHANGES_REQUESTED")])
  end

  test "dismissal replaces an earlier approval, and no reviews is not approval" do
    assert {:ok, false} = approval([review("owner", "APPROVED", "2026-08-10T10:00:00Z"), review("owner", "DISMISSED")])
    assert {:ok, false} = approval([])
  end

  test "propagates a failed strict read instead of reusing stored approval" do
    key = ResourceStore.key_for_repo(:pull_request_reviews, "owner/repo", 77)
    reviews = [review("owner", "APPROVED")]
    ResourceStore.put_resource(key, reviews, source: :webhook)

    assert {:error, {:github, :timeout, %{reason: :timeout}}} = HumanReviewGate.approved_pull_request?(77, request_fun: fn _req -> {:error, :timeout} end)
    assert ResourceStore.data(key) == reviews
  end

  test "conditionally revalidates the held review list" do
    key = ResourceStore.key_for_repo(:pull_request_reviews, "owner/repo", 77)
    ResourceStore.put_resource(key, [review("owner", "APPROVED")], source: :poll, etag: ~s("reviews-v1"))
    parent = self()

    request_fun = fn req ->
      assert req.method == :get
      assert req.url =~ "/repos/owner/repo/pulls/77/reviews?per_page=100"
      send(parent, {:requested, req.etag})
      {:ok, %{status: 304, headers: [{"etag", ~s("reviews-v1")}], body: nil}}
    end

    assert {:ok, true} = HumanReviewGate.approved_pull_request?(77, request_fun: request_fun)
    assert_received {:requested, ~s("reviews-v1")}
  end

  defp approval(reviews) do
    HumanReviewGate.approved_pull_request?(77, request_fun: fn _req -> {:ok, %{status: 200, body: reviews}} end)
  end

  defp review(login, state, submitted_at \\ "2026-08-10T11:00:00Z") do
    %{"user" => %{"login" => login}, "state" => state, "submitted_at" => submitted_at}
  end
end
