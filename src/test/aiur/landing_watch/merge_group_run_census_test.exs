defmodule Aiur.LandingWatch.MergeGroupRunCensusTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeGroups

  test "the stale-run census queries active and completed statuses separately" do
    parent = self()

    historical =
      Enum.map(
        1..501,
        &%{
          "id" => &1,
          "event" => "merge_group",
          "status" => "completed",
          "head_branch" => "gh-readonly-queue/main/pr-#{&1}-old"
        }
      )

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: []}}

      %{method: :get, url: url} ->
        send(parent, {:census, url})

        runs =
          if String.contains?(url, "status=in_progress"),
            do: [
              %{
                "id" => 900,
                "event" => "merge_group",
                "status" => "in_progress",
                "head_branch" => "gh-readonly-queue/main/pr-900-old"
              }
            ],
            else: historical

        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}

      %{method: :post, url: url} ->
        send(parent, {:cancel, url})
        {:ok, %{status: 202, body: %{}}}
    end

    assert :ok =
             MergeGroups.cancel_stale([],
               base_branch: "main",
               token: "test-gh-token",
               request_fun: request,
               live_observations_fun: fn _, _ -> {:ok, []} end
             )

    urls =
      for _ <- 1..5 do
        assert_received {:census, url}
        url
      end

    assert Enum.all?(urls, &String.contains?(&1, "event=merge_group"))
    assert Enum.any?(urls, &String.contains?(&1, "status=queued"))
    assert Enum.any?(urls, &String.contains?(&1, "status=in_progress"))
    assert Enum.any?(urls, &String.contains?(&1, "status=waiting"))
    assert Enum.any?(urls, &String.contains?(&1, "status=requested"))
    assert Enum.any?(urls, &String.contains?(&1, "status=completed"))

    assert_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/900/cancel"}

    refute_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/501/cancel"}
  end

  test "a run list longer than the page limit keeps the read pages instead of failing the poll" do
    parent = self()
    stale = %{"id" => 77, "event" => "merge_group", "status" => "in_progress", "head_branch" => "gh-readonly-queue/main/pr-7-old"}

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: []}}

      %{method: :get, url: url} ->
        if String.contains?(url, "status=completed"), do: send(parent, :completed_page)

        runs =
          if String.contains?(url, "status=in_progress"),
            do: [stale],
            else: [%{"id" => System.unique_integer([:positive]), "event" => "merge_group", "status" => "completed", "conclusion" => "success", "head_branch" => "gh-readonly-queue/main/pr-1-a"}]

        next = if String.contains?(url, "status=in_progress"), do: [], else: [{"link", "<#{url}&page=n>; rel=\"next\""}]
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}, headers: next}}

      %{method: :post, url: url} ->
        send(parent, {:cancel, url})
        {:ok, %{status: 202, body: %{}}}
    end

    assert :ok =
             MergeGroups.cancel_stale([],
               base_branch: "main",
               token: "test-gh-token",
               request_fun: request,
               live_observations_fun: fn _, _ -> {:ok, []} end
             )

    assert_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/77/cancel"}
    for _ <- 1..5, do: assert_received(:completed_page)
    refute_received :completed_page
  end
end
