defmodule Aiur.LandingWatch.MergeGroupsTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.ResourceStore
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

  test "the strict stale-run census revalidates each status list with its own ETag" do
    parent = self()
    base = "etag-census-test"
    statuses = ["queued", "in_progress", "waiting", "requested", "completed"]
    keys = Enum.map(statuses, &ResourceStore.key(:landing_merge_group_runs, "test-org", "test-repo", "#{base}:#{&1}:0"))
    on_exit(fn -> Enum.each(keys, &ResourceStore.drop_data/1) end)

    request = fn call ->
      status = call.url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.fetch!("status")
      send(parent, {:census_request, status, Map.get(call, :etag)})

      if is_binary(Map.get(call, :etag)) do
        {:ok, %{status: 304, headers: [{"etag", Map.get(call, :etag)}]}}
      else
        {:ok, %{status: 200, body: %{"workflow_runs" => []}, headers: [{"etag", ~s("#{status}-etag")}]}}
      end
    end

    opts = [base_branch: base, token: "test-gh-token", request_fun: request, live_observations_fun: fn _, _ -> {:ok, []} end]
    assert :ok = MergeGroups.cancel_stale([], opts)
    assert :ok = MergeGroups.cancel_stale([], opts)

    requests =
      for _ <- 1..10 do
        assert_received {:census_request, status, etag}
        {status, etag}
      end

    assert Enum.all?(Enum.take(requests, 5), fn {_status, etag} -> is_nil(etag) end)
    assert Enum.sort(Enum.map(Enum.drop(requests, 5), &elem(&1, 0))) == Enum.sort(statuses)
    assert Enum.all?(Enum.drop(requests, 5), fn {status, etag} -> etag == ~s("#{status}-etag") end)
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
