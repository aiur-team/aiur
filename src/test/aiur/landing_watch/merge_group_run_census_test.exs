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
end
