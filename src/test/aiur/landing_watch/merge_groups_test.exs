defmodule Aiur.LandingWatch.MergeGroupsTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeGroups

  test "only active merge-group runs without a live PR entry are cancelled" do
    parent = self()

    runs = [
      %{
        "id" => 31,
        "event" => "merge_group",
        "status" => "in_progress",
        "head_branch" => "gh-readonly-queue/main/pr-3-aaa"
      },
      %{
        "id" => 32,
        "event" => "merge_group",
        "status" => "queued",
        "head_branch" => "gh-readonly-queue/main/pr-4-bbb"
      },
      %{
        "id" => 33,
        "event" => "merge_group",
        "status" => "completed",
        "head_branch" => "gh-readonly-queue/main/pr-5-ccc"
      },
      %{
        "id" => 34,
        "event" => "merge_group",
        "status" => "in_progress",
        "head_branch" => "gh-readonly-queue/main/pr-3-aaa-pr-4-bbb"
      }
    ]

    request = fn
      %{method: :get} ->
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}

      %{method: :post, url: url} ->
        send(parent, {:cancel, url})
        {:ok, %{status: 202, body: %{}}}
    end

    observations = [%{number: 3, base: "main", merge_queue_entry: %{"id" => "entry-3"}}]

    assert :ok =
             MergeGroups.cancel_stale(observations,
               base_branch: "main",
               token: "test-gh-token",
               request_fun: request,
               live_observations_fun: fn _, _ -> {:ok, observations} end
             )

    assert_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/32/cancel"}

    assert_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/34/cancel"}

    refute_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/31/cancel"}
  end

  test "an active run built before the currently queued PR head is cancelled" do
    parent = self()

    runs = [
      %{
        "id" => 41,
        "event" => "merge_group",
        "status" => "in_progress",
        "head_branch" => "gh-readonly-queue/main/pr-3-aaa",
        "created_at" => "2026-10-13T23:59:00Z"
      },
      %{
        "id" => 42,
        "event" => "merge_group",
        "status" => "in_progress",
        "head_branch" => "gh-readonly-queue/main/pr-3-aaa",
        "created_at" => "2026-10-14T00:01:00Z"
      }
    ]

    request = fn
      %{method: :get} ->
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}

      %{method: :post, url: url} ->
        send(parent, {:cancel, url})
        {:ok, %{status: 202, body: %{}}}
    end

    observations = [
      %{
        number: 3,
        base: "main",
        head: "head-current",
        head_committed_at: "2026-10-14T00:00:00Z",
        merge_queue_entry: %{
          "id" => "entry-new",
          "pullRequest" => %{"headRefOid" => "head-current"}
        }
      }
    ]

    assert :ok =
             MergeGroups.cancel_stale(observations,
               base_branch: "main",
               token: "test-gh-token",
               request_fun: request,
               live_observations_fun: fn _, _ -> {:ok, observations} end
             )

    assert_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/41/cancel"}

    refute_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/42/cancel"}
  end

  test "queue is re-observed after the active-run census before cancelling" do
    parent = self()

    runs = [
      %{
        "id" => 91,
        "event" => "merge_group",
        "status" => "in_progress",
        "head_branch" => "gh-readonly-queue/main/pr-9-abc",
        "created_at" => "2026-10-14T00:01:00Z"
      }
    ]

    request = fn
      %{method: :get} ->
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}

      %{method: :post, url: url} ->
        send(parent, {:cancel, url})
        {:ok, %{status: 202, body: %{}}}
    end

    newly_enqueued = [
      %{
        number: 9,
        base: "main",
        head: "head-now",
        head_committed_at: "2026-10-14T00:00:00Z",
        merge_queue_entry: %{"id" => "entry", "pullRequest" => %{"headRefOid" => "head-now"}}
      }
    ]

    assert :ok =
             MergeGroups.cancel_stale([],
               base_branch: "main",
               token: "test-gh-token",
               request_fun: request,
               live_observations_fun: fn _, _ -> {:ok, newly_enqueued} end
             )

    refute_received {:cancel, _}
  end
end
