defmodule Aiur.LandingWatch.MergeGroupsGroupHeadTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.LandingWatch.MergeGroups

  defp run(id, sha, pr, status \\ "in_progress"),
    do: %{"id" => id, "event" => "merge_group", "status" => status, "head_sha" => sha, "head_branch" => "gh-readonly-queue/main/pr-#{pr}-base"}

  defp cancel_stale(base, runs, cancel_fun, observations \\ nil) do
    observations =
      observations ||
        [
          %{number: 3, base: base, merge_queue_entry: %{"id" => "entry-3", "headCommit" => %{"oid" => "group-3-new"}}},
          %{number: 4, base: base, merge_queue_entry: %{"id" => "entry-4", "headCommit" => %{"oid" => "group-4-new"}}}
        ]

    MergeGroups.cancel_stale(observations,
      base_branch: base,
      token: "test-gh-token",
      request_fun: fn %{method: :get} -> {:ok, %{status: 200, body: %{"workflow_runs" => runs}}} end,
      live_observations_fun: fn _, _ -> {:ok, observations} end,
      cancel_fun: cancel_fun
    )
  end

  test "a run for a rebuilt group head is cancelled while live group runs keep running" do
    parent = self()
    runs = [run(51, "group-3-old", 3), run(52, "group-4-old", 4, "queued"), run(53, "group-3-new", 3), run(54, "group-4-new", 4, "queued")]

    cancel = fn id, opts ->
      send(parent, {:cancel, id, opts[:caller]})
      :ok
    end

    log = capture_log([level: :info], fn -> assert :ok = cancel_stale("group-head-live", runs, cancel) end)

    assert_received {:cancel, 51, "landing_watch_stale_merge_group_cancel"}
    assert_received {:cancel, 52, "landing_watch_stale_merge_group_cancel"}
    refute_received {:cancel, 53, _}
    refute_received {:cancel, 54, _}
    assert log =~ "cancelled stale merge-group run 51 head=group-3-old"
    assert log =~ "cancelled stale merge-group run 52 head=group-4-old"
  end

  test "a failed cancel is logged and the remaining stale runs are still cancelled" do
    parent = self()

    cancel = fn
      61, _opts ->
        {:error, :boom}

      id, _opts ->
        send(parent, {:cancel, id})
        :ok
    end

    log = capture_log(fn -> assert :ok = cancel_stale("group-head-failure", [run(61, "dead-a", 3), run(62, "dead-b", 4)], cancel) end)

    assert_received {:cancel, 62}
    assert log =~ "could not cancel stale merge-group run 61: :boom"
  end

  test "with no observed group heads no run is cancelled" do
    base = "group-head-none"
    runs = [run(71, "group-3-any", 3), run(72, "group-4-any", 4, "queued")]
    cancel = fn id, _opts -> flunk("cancelled run #{id}") end
    headless = [%{number: 3, base: base, merge_queue_entry: %{"id" => "entry-3", "headCommit" => nil}}, %{number: 4, base: base, merge_queue_entry: %{"id" => "entry-4"}}]

    assert :ok = cancel_stale(base, runs, cancel, headless)
    assert :ok = cancel_stale(base, runs, cancel, [])
  end

  test "the live queue query reads each entry's group head through the default observer" do
    parent = self()
    base = "group-head-observer"
    runs = [run(81, "group-5-old", 5), run(82, "group-5-new", 5)]

    request = fn
      %{method: :get} ->
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}

      %{body: %{"query" => query}} ->
        assert query =~ "mergeQueueEntry { id headCommit { oid }"
        entry = %{"id" => "entry-5", "headCommit" => %{"oid" => "group-5-new"}, "pullRequest" => %{"id" => "PR_5", "headRefOid" => "head-5"}}
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pr_0" => %{"id" => "PR_5", "headRefOid" => "head-5", "baseRefName" => base, "mergeQueueEntry" => entry}}}}}}
    end

    observations = [%{number: 5, base: base, rest: %{"number" => 5}, merge_queue_entry: %{"id" => "entry-5"}}]

    capture_log(fn ->
      assert :ok =
               MergeGroups.cancel_stale(observations,
                 base_branch: base,
                 token: "test-gh-token",
                 request_fun: request,
                 cancel_fun: fn id, _opts -> send(parent, {:cancel, id}) && :ok end
               )
    end)

    assert_received {:cancel, 81}
    refute_received {:cancel, 82}
  end
end
