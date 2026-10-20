defmodule Aiur.LandingWatch.MergeGroupsGroupHeadTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.LandingWatch.MergeGroups

  defp run(id, sha, pr, status, base, created_at \\ "2026-10-19T10:00:00Z"),
    do: %{
      "id" => id,
      "event" => "merge_group",
      "status" => status,
      "head_sha" => sha,
      "head_branch" => "gh-readonly-queue/#{base}/pr-#{pr}-base",
      "created_at" => created_at
    }

  defp cancel_stale(base, runs, cancel_fun, observations \\ nil) do
    observations =
      observations ||
        [
          %{
            number: 3,
            base: base,
            head: "pr-head-3",
            head_committed_at: "2026-10-19T09:00:00Z",
            merge_queue_entry: %{
              "id" => "entry-3",
              "headCommit" => %{"oid" => "group-3-new", "committedDate" => "2026-10-19T11:00:00Z"},
              "pullRequest" => %{"headRefOid" => "pr-head-3"}
            }
          },
          %{
            number: 4,
            base: base,
            head: "pr-head-4",
            head_committed_at: "2026-10-19T09:00:00Z",
            merge_queue_entry: %{
              "id" => "entry-4",
              "headCommit" => %{"oid" => "group-4-new", "committedDate" => "2026-10-19T11:00:00Z"},
              "pullRequest" => %{"headRefOid" => "pr-head-4"}
            }
          }
        ]

    MergeGroups.cancel_stale(observations,
      base_branch: base,
      token: "test-gh-token",
      request_fun: fn %{method: :get} ->
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
      end,
      live_observations_fun: fn _, _ -> {:ok, observations} end,
      cancel_fun: cancel_fun
    )
  end

  test "a run for a rebuilt group head is cancelled while live group runs keep running" do
    parent = self()

    runs = [
      run(51, "group-3-old", 3, "in_progress", "group-head-live"),
      run(52, "group-4-old", 4, "queued", "group-head-live"),
      run(53, "group-3-new", 3, "in_progress", "group-head-live", "2026-10-19T12:00:00Z"),
      run(54, "group-4-new", 4, "queued", "group-head-live", "2026-10-19T12:00:00Z"),
      run(55, "group-3-in-flight", 3, "in_progress", "group-head-live", "2026-10-19T12:00:00Z")
    ]

    cancel = fn id, opts ->
      send(parent, {:cancel, id, opts[:caller]})
      :ok
    end

    log =
      capture_log([level: :info], fn ->
        assert :ok = cancel_stale("group-head-live", runs, cancel)
      end)

    assert_received {:cancel, 51, "landing_watch_stale_merge_group_cancel"}
    assert_received {:cancel, 52, "landing_watch_stale_merge_group_cancel"}
    refute_received {:cancel, 53, _}
    refute_received {:cancel, 54, _}
    refute_received {:cancel, 55, _}
    assert log =~ "cancelled merge-group run id=51 head=group-3-old reason=group_head_not_live"
    assert log =~ "cancelled merge-group run id=52 head=group-4-old reason=group_head_not_live"
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

    log =
      capture_log(fn ->
        assert :ok =
                 cancel_stale(
                   "group-head-failure",
                   [
                     run(61, "dead-a", 3, "in_progress", "group-head-failure"),
                     run(62, "dead-b", 4, "in_progress", "group-head-failure")
                   ],
                   cancel
                 )
      end)

    assert_received {:cancel, 62}

    assert log =~
             "could not cancel merge-group run id=61 head=dead-a reason=group_head_not_live: :boom"
  end

  test "with no observed group heads no run is cancelled" do
    base = "group-head-none"

    runs = [
      run(71, "group-3-any", 3, "in_progress", base),
      run(72, "group-4-any", 4, "queued", base)
    ]

    cancel = fn id, _opts -> flunk("cancelled run #{id}") end

    headless = [
      %{number: 3, base: base, merge_queue_entry: %{"id" => "entry-3", "headCommit" => nil}},
      %{number: 4, base: base, merge_queue_entry: %{"id" => "entry-4"}}
    ]

    assert :ok = cancel_stale(base, runs, cancel, headless)
    assert :ok = cancel_stale(base, runs, cancel, headless)
  end

  test "a missing group head in a partial snapshot does not cancel that PR's run" do
    base = "group-head-partial"
    runs = [run(75, "group-4-old", 4, "in_progress", base)]

    partial = [
      %{
        number: 3,
        base: base,
        merge_queue_entry: %{"id" => "entry-3", "headCommit" => %{"oid" => "group-3-live"}}
      },
      %{number: 4, base: base, merge_queue_entry: %{"id" => "entry-4", "headCommit" => nil}}
    ]

    assert :ok =
             cancel_stale(
               base,
               runs,
               fn id, _ -> flunk("cancelled run #{id} from a partial group snapshot") end,
               partial
             )
  end

  test "the live queue query reads each entry's group head through the default observer" do
    parent = self()
    base = "group-head-observer"

    runs = [
      run(81, "group-5-old", 5, "in_progress", base),
      run(82, "group-5-new", 5, "in_progress", base)
    ]

    request = fn
      %{method: :get} ->
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}

      %{body: %{"query" => query}} ->
        assert query =~ "mergeQueueEntry { id state headCommit { oid committedDate }"

        entry = %{
          "id" => "entry-5",
          "state" => "MERGEABLE",
          "headCommit" => %{"oid" => "group-5-new", "committedDate" => "2026-10-19T11:00:00Z"},
          "pullRequest" => %{"id" => "PR_5", "headRefOid" => "head-5"}
        }

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{
                 "pr_0" => %{
                   "id" => "PR_5",
                   "headRefOid" => "head-5",
                   "baseRefName" => base,
                   "mergeQueueEntry" => entry
                 }
               }
             }
           }
         }}
    end

    observations = [
      %{number: 5, base: base, rest: %{"number" => 5}, merge_queue_entry: %{"id" => "entry-5"}}
    ]

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
