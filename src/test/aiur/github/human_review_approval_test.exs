defmodule Aiur.GitHub.HumanReviewApprovalTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{BlockerProgress, HumanReviewGate, ResourceStore}

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

  test "unknown blocker identity uses the held canonical PR and reads only reviews" do
    hold_pr("owner/repo", false)
    parent = self()

    request = fn req ->
      send(parent, {:request, req.url})
      {:ok, %{status: 200, body: [review("owner", "APPROVED")]}}
    end

    assert {:ok, %{pr_number: 88, stage: :pr_approved, head_sha: "head"}} = BlockerProgress.approval("12", nil, request_fun: request)
    assert_received {:request, url}
    assert url =~ "/pulls/88/reviews?per_page=100"
    refute_received {:request, _second}
  end

  test "missing and draft blocker identity make no remote requests on repeated reads" do
    parent = self()

    request = fn _req ->
      send(parent, :unexpected_request)
      {:error, :not_allowed}
    end

    for _ <- 1..2, do: assert({:ok, nil} == BlockerProgress.approval("12", nil, request_fun: request))
    hold_pr("owner/repo", true)
    assert {:ok, nil} = BlockerProgress.approval("12", nil, request_fun: request)
    refute_received :unexpected_request
  end

  test "a held fork branch cannot supply watched approval and triggers no remote read" do
    hold_pr("fork/repo", false)
    parent = self()

    request = fn _req ->
      send(parent, :unexpected_request)
      {:error, :not_allowed}
    end

    assert {:ok, nil} = BlockerProgress.approval("12", nil, request_fun: request)
    refute_received :unexpected_request
  end

  defp hold_pr(repo, draft?) do
    key = ResourceStore.key_for_repo(:branch_pull_request, "owner/repo", "12")

    ResourceStore.put_resource(key, %{"number" => 88, "state" => "open", "draft" => draft?, "head" => %{"ref" => "aiur/12-progress", "sha" => "head", "repo" => %{"full_name" => repo}}},
      source: :webhook
    )
  end

  defp approval(reviews) do
    HumanReviewGate.approved_pull_request?(77, request_fun: fn _req -> {:ok, %{status: 200, body: reviews}} end)
  end

  defp review(login, state, submitted_at \\ "2026-08-10T11:00:00Z") do
    %{"user" => %{"login" => login}, "state" => state, "submitted_at" => submitted_at}
  end
end
