defmodule Aiur.RecentMergeStoreTest do
  use ExUnit.Case, async: false

  alias Aiur.{RecentMerge, RecentMergeStore}

  @now ~U[2026-07-12 18:00:00Z]

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-recent-merges")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a live merge is bounded, attributed only to its proven ticket, and survives restart", %{dir: dir} do
    secret = "ghp_" <> String.duplicate("A", 36)

    event =
      merged_event(%{
        "id" => "evt-live",
        "payload" => %{
          "action" => "closed",
          "pull_request" =>
            merged_pr(%{
              "title" => "Ship #{secret}",
              "body" => String.duplicate("summary ", 100),
              "head" => %{"ref" => "aiur/983-decision-history", "sha" => "head-983"}
            })
        }
      })

    assert {:ok, merge} =
             RecentMerge.from_github_event(event,
               live?: true,
               run_id: "run-live",
               now: @now
             )

    assert merge.id == "owner/repo#42"
    assert merge.ticket_id == "983"
    assert merge.live_observed?
    refute merge.backfilled?
    assert merge.observed_run_id == "run-live"
    assert merge.url == "https://github.com/owner/repo/pull/42"
    assert merge.title =~ "[REDACTED:ghp]"
    refute merge.title =~ secret
    assert String.length(merge.summary) <= 500

    pid = start_store!(dir)
    assert {:ok, %{status: :accepted, merge: stored}} = RecentMergeStore.upsert(merge, pid)
    assert [stored] == RecentMergeStore.list(pid)
    GenServer.stop(pid)

    replayed = start_store!(dir)
    assert [stored] == RecentMergeStore.list(replayed)
    assert RecentMergeStore.health(replayed) == :writable

    %File.Stat{mode: mode} = File.stat!(Path.join(dir, "recent_merges.ndjson"))
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "a backfilled repository merge makes no ticket, agent, or run claim", %{dir: dir} do
    event =
      merged_event(%{
        "id" => "evt-backfill",
        "payload" => %{
          "action" => "closed",
          "pull_request" =>
            merged_pr(%{
              "head" => %{"ref" => "release/2026-07", "sha" => "release-head"},
              "merged_by" => nil
            })
        }
      })

    assert {:ok, merge} =
             RecentMerge.from_github_event(event,
               live?: false,
               run_id: "must-not-leak",
               now: @now
             )

    assert merge.backfilled?
    refute merge.live_observed?
    assert merge.observed_run_id == nil
    assert merge.ticket_id == nil
    assert merge.merged_by == nil

    pid = start_store!(dir)
    assert {:ok, %{status: :accepted}} = RecentMergeStore.upsert(merge, pid)
    assert [%RecentMerge{ticket_id: nil, observed_run_id: nil}] = RecentMergeStore.list(pid)
  end

  test "normalizes a sparse action=merged event from its top-level timestamp" do
    event =
      merged_event()
      |> put_in(["payload", "action"], "merged")
      |> update_in(["payload", "pull_request"], &Map.drop(&1, ["merged", "merged_at"]))

    assert {:ok, %RecentMerge{merged_at: ~U[2026-07-12 17:59:00Z], ticket_id: "983"}} =
             RecentMerge.from_github_event(event, live?: true, run_id: "run-live", now: @now)
  end

  test "derives every same-repository closing ticket from a merged PR body" do
    assert closing_identifiers_for("Closes #1570\nFixes #1571\nResolves #1572") == ["1570", "1571", "1572"]
  end

  test "a comma-chained bare reference does not inherit the preceding keyword" do
    # GitHub closes only #1570 here: the keyword does not carry across the
    # comma. Treating #1571 as closed would close a ticket the PR never did.
    assert closing_identifiers_for("Closes #1570, #1571") == ["1570"]
    assert closing_identifiers_for("Closes #1570, closes #1571") == ["1570", "1571"]
  end

  test "ignores closing keywords GitHub itself ignores" do
    assert closing_identifiers_for("Some notes\n```\nCloses #4242\n```\n") == []
    assert closing_identifiers_for("> Closes #999") == []
    assert closing_identifiers_for("Use `Closes #77` in the body") == []
  end

  test "ignores a closing keyword buried in prose" do
    assert closing_identifiers_for("See also closed #55 last week") == []
  end

  test "accepts the documented keyword set, list items, and owner/repo references" do
    assert closing_identifiers_for("- fixed #1\n* Resolve #2\n1. CLOSE #3") == ["1", "2", "3"]
    assert closing_identifiers_for("Closes owner/repo#1570") == ["1570"]
    assert closing_identifiers_for("Closes other/repo#1570") == []
  end

  test "retains closing references beyond the bounded merged PR summary" do
    event =
      merged_event(%{
        "payload" => %{
          "pull_request" => merged_pr(%{"body" => String.duplicate("x", 600) <> "\nCloses #1570"})
        }
      })

    assert {:ok, merge} = RecentMerge.from_github_event(event, live?: false, now: @now)
    assert String.length(merge.summary) <= 500
    assert RecentMerge.closing_issue_identifiers(merge) == ["1570"]
  end

  test "each reference retained past the summary bound keeps its own keyword" do
    body = String.duplicate("x", 600) <> "\nCloses #1570\nCloses #1571"

    event =
      merged_event(%{"payload" => %{"pull_request" => merged_pr(%{"body" => body})}})

    assert {:ok, merge} = RecentMerge.from_github_event(event, live?: false, now: @now)
    assert String.length(merge.summary) <= 500
    assert RecentMerge.closing_issue_identifiers(merge) == ["1570", "1571"]
  end

  test "repeated rows dedupe while a later live observation appends one enriched snapshot", %{dir: dir} do
    event = merged_event()

    assert {:ok, backfill} =
             RecentMerge.from_github_event(event,
               live?: false,
               now: @now
             )

    assert {:ok, live} =
             RecentMerge.from_github_event(event,
               live?: true,
               run_id: "run-later",
               now: DateTime.add(@now, 60, :second)
             )

    pid = start_store!(dir)
    assert {:ok, %{status: :accepted}} = RecentMergeStore.upsert(backfill, pid)
    assert {:ok, %{status: :duplicate}} = RecentMergeStore.upsert(backfill, pid)
    assert {:ok, %{status: :accepted, merge: enriched}} = RecentMergeStore.upsert(live, pid)

    assert enriched.backfilled?
    assert enriched.live_observed?
    assert enriched.observed_run_id == "run-later"
    assert {:ok, [^backfill, ^enriched]} = RecentMergeStore.history(backfill.id, pid)

    assert Path.join(dir, "recent_merges.ndjson")
           |> File.read!()
           |> String.split("\n", trim: true)
           |> length() == 2
  end

  test "only canonical legacy or readable Aiur branches derive a ticket" do
    for {branch, ticket_id} <- [
          {"aiur/983", "983"},
          {"aiur/983-decision-history", "983"},
          {"feature/983", nil},
          {"aiur/not-a-ticket", nil},
          {"../aiur/983", nil}
        ] do
      event =
        merged_event(%{
          "payload" => %{
            "action" => "closed",
            "pull_request" => merged_pr(%{"head" => %{"ref" => branch, "sha" => "head"}})
          }
        })

      assert {:ok, %RecentMerge{ticket_id: ^ticket_id}} =
               RecentMerge.from_github_event(event, live?: false, now: @now)
    end
  end

  test "malformed facts and unsafe URLs are rejected before persistence" do
    unsafe =
      merged_event(%{
        "payload" => %{
          "action" => "closed",
          "pull_request" => merged_pr(%{"html_url" => "http://github.com/owner/repo/pull/42"})
        }
      })

    assert {:error, {:recent_merge_invalid, {:url, :unsafe}}} =
             RecentMerge.from_github_event(unsafe, live?: false, now: @now)

    malformed =
      merged_event(%{
        "payload" => %{
          "action" => "closed",
          "pull_request" => merged_pr(%{"merged_at" => "not-a-time"})
        }
      })

    assert {:error, {:recent_merge_invalid, {:merged_at, :invalid_timestamp}}} =
             RecentMerge.from_github_event(malformed, live?: false, now: @now)
  end

  test "a torn tail is truncated, while interior corruption keeps prefix reads and fails closed", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, merge} = RecentMerge.from_github_event(merged_event(), live?: false, now: @now)
    assert {:ok, %{status: :accepted}} = RecentMergeStore.upsert(merge, pid)
    GenServer.stop(pid)

    path = Path.join(dir, "recent_merges.ndjson")
    File.write!(path, ~s({"incomplete":), [:append])

    repaired = start_store!(dir)
    assert RecentMergeStore.health(repaired) == :writable
    assert [merge] == RecentMergeStore.list(repaired)
    assert File.read!(path) |> String.ends_with?("\n")
    GenServer.stop(repaired)

    File.write!(path, "not-json\n", [:append])
    corrupted = start_store!(dir)

    assert {:corrupt, 2, _reason} = RecentMergeStore.health(corrupted)
    assert [merge] == RecentMergeStore.list(corrupted)

    assert {:error, {:store_unavailable, {:corrupt, 2, _reason}}} =
             RecentMergeStore.upsert(merge, corrupted)
  end

  test "durable append failure does not alter current state", %{dir: dir} do
    {:ok, append_mode} = Agent.start_link(fn -> :fail end)

    append_fun = fn path, record ->
      case Agent.get(append_mode, & &1) do
        :fail -> {:error, :disk_full}
        :ok -> Aiur.DecisionLog.append(path, record)
      end
    end

    pid = start_store!(dir, append_fun: append_fun)
    assert {:ok, merge} = RecentMerge.from_github_event(merged_event(), live?: true, run_id: "run", now: @now)

    assert {:error, {:append_failed, :disk_full}} = RecentMergeStore.upsert(merge, pid)
    assert RecentMergeStore.list(pid) == []
    assert RecentMergeStore.health(pid) == {:append_failed, :disk_full}

    Agent.update(append_mode, fn _ -> :ok end)
    assert {:ok, %{status: :accepted}} = RecentMergeStore.upsert(merge, pid)
    assert RecentMergeStore.health(pid) == :writable
  end

  test "retention bounds current rows, histories, and the durable log", %{dir: dir} do
    pid =
      start_store!(dir,
        retention_limit: 5,
        compaction_record_limit: 7
      )

    for number <- 1..12 do
      merge = merge_for_number(number)
      assert {:ok, %{status: :accepted, merge: ^merge}} = RecentMergeStore.upsert(merge, pid)
    end

    assert Enum.map(RecentMergeStore.list(pid), & &1.number) == [12, 11, 10, 9, 8]

    for number <- 1..7 do
      assert {:error, :not_found} = RecentMergeStore.history("owner/repo##{number}", pid)
    end

    assert {:ok, [%RecentMerge{number: 8}]} = RecentMergeStore.history("owner/repo#8", pid)

    path = Path.join(dir, "recent_merges.ndjson")
    assert path |> File.read!() |> String.split("\n", trim: true) |> length() <= 7

    GenServer.stop(pid)

    replayed =
      start_store!(dir,
        retention_limit: 5,
        compaction_record_limit: 7
      )

    assert Enum.map(RecentMergeStore.list(replayed), & &1.number) == [12, 11, 10, 9, 8]
    assert {:error, :not_found} = RecentMergeStore.history("owner/repo#7", replayed)
  end

  test "an unavailable store emits an operator attention", %{dir: dir} do
    blocked_path = Path.join(dir, "not-a-directory")
    File.mkdir_p!(dir)
    File.write!(blocked_path, "blocked")
    parent = self()

    alert_fun = fn topic, message, opts ->
      send(parent, {:store_alert, topic, message, opts})
      :ok
    end

    pid = start_store!(blocked_path, alert_fun: alert_fun)

    assert {:unavailable, {:directory_unavailable, {:not_a_directory, ^blocked_path}}} =
             RecentMergeStore.health(pid)

    assert_receive {:store_alert, "recent_merge_store.unavailable", message, opts}
    assert message =~ "read-only"
    assert opts[:needs_attention]
  end

  test "reconciliation status keeps a saturated window disclosed", %{dir: dir} do
    pid = start_store!(dir)
    assert %{status: :unknown, partial?: nil, pages_fetched: 0} = RecentMergeStore.reconciliation(pid)

    assert :ok = RecentMergeStore.mark_reconciliation(false, 2, pid)
    assert %{status: :complete, partial?: false, pages_fetched: 2} = RecentMergeStore.reconciliation(pid)

    assert :ok = RecentMergeStore.mark_reconciliation(true, 5, pid)
    assert %{status: :partial, partial?: true, pages_fetched: 5} = RecentMergeStore.reconciliation(pid)

    assert :ok = RecentMergeStore.mark_reconciliation(false, 1, pid)
    assert %{status: :partial, partial?: true, pages_fetched: 5} = RecentMergeStore.reconciliation(pid)
  end

  defp closing_identifiers_for(body) do
    event = merged_event(%{"payload" => %{"pull_request" => merged_pr(%{"body" => body})}})

    assert {:ok, merge} = RecentMerge.from_github_event(event, live?: false, now: @now)
    RecentMerge.closing_issue_identifiers(merge)
  end

  defp start_store!(dir, opts \\ []) do
    opts =
      Keyword.merge(
        [name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end],
        opts
      )

    {:ok, pid} = RecentMergeStore.start_link(opts)
    pid
  end

  defp merged_event(overrides \\ %{}) do
    base = %{
      "id" => "evt-42",
      "type" => "PullRequestEvent",
      "created_at" => "2026-07-12T17:59:00Z",
      "actor" => %{"login" => "event-actor"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => merged_pr()
      }
    }

    deep_merge(base, overrides)
  end

  defp merge_for_number(number) do
    merged_at = DateTime.add(@now, number, :second)

    event =
      merged_event(%{
        "id" => "evt-#{number}",
        "payload" => %{
          "pull_request" =>
            merged_pr(%{
              "number" => number,
              "html_url" => "https://github.com/owner/repo/pull/#{number}",
              "merged_at" => DateTime.to_iso8601(merged_at),
              "head" => %{"ref" => "release/#{number}", "sha" => "head-#{number}"}
            })
        }
      })

    assert {:ok, merge} = RecentMerge.from_github_event(event, live?: false, now: merged_at)
    merge
  end

  defp merged_pr(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 42,
        "title" => "Ship the control center",
        "body" => "Adds operator history and outcomes.",
        "html_url" => "https://github.com/owner/repo/pull/42",
        "merged" => true,
        "merged_at" => "2026-07-12T17:58:00Z",
        "merge_commit_sha" => "merge-42",
        "head" => %{"ref" => "aiur/983-decision-history", "sha" => "head-42"},
        "merged_by" => %{"login" => "merger"}
      },
      overrides
    )
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value),
        do: deep_merge(left_value, right_value),
        else: right_value
    end)
  end
end
