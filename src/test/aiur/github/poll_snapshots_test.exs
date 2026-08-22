defmodule Aiur.GitHub.PollSnapshotsTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{PollSnapshots, ResourceStore}

  @repo "owner/repo"

  setup do
    ResourceStore.reset()
    :ok
  end

  test "a webhook-advanced complete thread collection is fresh but a poll write is not" do
    assert :ok = PollSnapshots.put_review_threads(@repo, 77, [thread("PRRT_1", false, "2026-08-21T10:00:00Z")])
    assert :miss = PollSnapshots.review_threads(@repo, 77)

    assert :ok = PollSnapshots.merge_review_thread(@repo, 77, thread("PRRT_1", true, "2026-08-21T10:01:00Z"))
    assert {:ok, [%{"id" => "PRRT_1", "isResolved" => true}]} = PollSnapshots.review_threads(@repo, 77)
  end

  test "delivery freshness is bounded independently from store retention" do
    assert :ok = PollSnapshots.put_review_threads(@repo, 77, [thread("PRRT_1", false, "2026-08-21T10:00:00Z")])
    assert :ok = PollSnapshots.merge_review_thread(@repo, 77, thread("PRRT_1", true, "2026-08-21T10:01:00Z"))
    assert {:ok, %{fetched_at_ms: fetched_at_ms}} = ResourceStore.fetch(PollSnapshots.review_threads_key(@repo, 77))

    assert :miss = PollSnapshots.review_threads(@repo, 77, now_ms: fetched_at_ms + 30_001)
    assert {:ok, %{source: :webhook}} = ResourceStore.fetch(PollSnapshots.review_threads_key(@repo, 77))
  end

  test "a late thread delivery cannot roll a newer thread backward" do
    assert :ok = PollSnapshots.put_review_threads(@repo, 77, [thread("PRRT_1", false, "2026-08-21T10:02:00Z")])
    assert :ok = PollSnapshots.merge_review_thread(@repo, 77, thread("PRRT_1", true, "2026-08-21T10:03:00Z"))
    assert :unchanged = PollSnapshots.merge_review_thread(@repo, 77, thread("PRRT_1", false, "2026-08-21T10:01:00Z"))

    assert {:ok, [%{"isResolved" => true}]} = PollSnapshots.review_threads(@repo, 77)
  end

  test "an unknown thread delta cannot make an incomplete collection delivery-fresh" do
    assert :ok = PollSnapshots.put_review_threads(@repo, 77, [thread("PRRT_1", false, "2026-08-21T10:00:00Z")])

    assert :unchanged =
             PollSnapshots.merge_review_thread(@repo, 77, thread("PRRT_unknown", true, "2026-08-21T10:01:00Z"))

    assert :miss = PollSnapshots.review_threads(@repo, 77)
  end

  test "a webhook check run advances only a complete snapshot for the same head" do
    assert :ok =
             PollSnapshots.put_ci_contexts(
               @repo,
               42,
               "head-1",
               [check_run(501, "queued", nil, "2026-08-21T10:00:00Z")],
               %{"state" => "pending", "statuses" => []}
             )

    assert :miss = PollSnapshots.ci_contexts(@repo, 42)
    assert :unchanged = PollSnapshots.merge_check_run(@repo, 42, "head-2", check_run(501, "completed", "success", "2026-08-21T10:01:00Z"))

    assert :ok = PollSnapshots.merge_check_run(@repo, 42, "head-1", check_run(501, "completed", "success", "2026-08-21T10:01:00Z"))

    assert {:ok,
            %{
              "head_sha" => "head-1",
              "check_runs" => [%{"id" => 501, "status" => "completed", "conclusion" => "success"}]
            }} = PollSnapshots.ci_contexts(@repo, 42)
  end

  test "an unversioned check-run delivery cannot roll a versioned run backward" do
    assert :ok =
             PollSnapshots.put_ci_contexts(
               @repo,
               42,
               "head-1",
               [check_run(501, "completed", "success", "2026-08-21T10:01:00Z")],
               %{"state" => "success", "statuses" => []}
             )

    delivered =
      check_run(501, "queued", nil, nil)
      |> Map.put("started_at", nil)

    assert :unchanged = PollSnapshots.merge_check_run(@repo, 42, "head-1", delivered)
    assert :miss = PollSnapshots.ci_contexts(@repo, 42)
  end

  test "a poll that began before a webhook write cannot replace it" do
    started_at_ms = System.system_time(:millisecond) - 1

    assert :ok =
             PollSnapshots.put_ci_contexts(
               @repo,
               42,
               "head-1",
               [check_run(501, "queued", nil, "2026-08-21T10:00:00Z")],
               %{"state" => "pending", "statuses" => []}
             )

    assert :ok = PollSnapshots.merge_check_run(@repo, 42, "head-1", check_run(501, "completed", "success", "2026-08-21T10:01:00Z"))

    assert :unchanged =
             PollSnapshots.put_ci_contexts(
               @repo,
               42,
               "head-1",
               [check_run(501, "queued", nil, "2026-08-21T10:00:00Z")],
               %{"state" => "pending", "statuses" => []},
               started_at_ms: started_at_ms
             )

    assert {:ok, %{"check_runs" => [%{"status" => "completed"}]}} = PollSnapshots.ci_contexts(@repo, 42)
  end

  defp thread(id, resolved, updated_at) do
    %{
      "id" => id,
      "isResolved" => resolved,
      "updatedAt" => updated_at,
      "path" => "src/lib/example.ex",
      "line" => 7,
      "comments" => %{"nodes" => []}
    }
  end

  defp check_run(id, status, conclusion, completed_at) do
    %{
      "id" => id,
      "name" => "test",
      "status" => status,
      "conclusion" => conclusion,
      "started_at" => "2026-08-21T09:59:00Z",
      "completed_at" => completed_at,
      "output" => %{}
    }
  end
end
