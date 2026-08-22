defmodule Aiur.Orchestrator.MergedTicketDispatchTest do
  @moduledoc """
  Covers the dispatcher call site itself: the poll cycle reconciles merged
  tickets against the real `Aiur.RecentMergeStore` before the surviving
  candidates reach state sync, capacity alerts, and dispatch.
  """

  use ExUnit.Case, async: true

  alias Aiur.{Issue, RecentMerge, RecentMergeStore}
  alias Aiur.Orchestrator.{Dispatcher, State}

  @now ~U[2026-07-12 18:00:00Z]

  # `Aiur.RecentMergeStore` is part of the application supervision tree, so the
  # store this test drives is a private, unnamed instance over its own state
  # directory: claiming the registered name would collide with the supervised
  # one, and writing into the supervised one would leak merge records into
  # every later test that reads it.
  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-merged-dispatch-#{System.pid()}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    store =
      start_supervised!({RecentMergeStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end})

    %{store: store}
  end

  test "the dispatcher drops a ticket a stored merged PR closed and keeps the rest", %{store: store} do
    assert {:ok, _} = RecentMergeStore.upsert(merge_closing("Closes #1570"), store)

    closed = %Issue{id: "issue-1570", identifier: "1570", state: "Todo"}
    open = %Issue{id: "issue-1571", identifier: "1571", state: "Todo"}
    parent = self()

    {_state, candidates} =
      Dispatcher.reconcile_merged_tickets(%State{}, [closed, open],
        recent_merges_fun: fn -> RecentMergeStore.list(store) end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn identifier, state_name, expected ->
          send(parent, {:transition, identifier, state_name, expected})
          :ok
        end,
        resume_blockees_fun: fn state, _identifier -> state end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
      )

    assert candidates == [open]
    assert_receive {:transition, "1570", "done", "Todo"}
    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", _opts}
    refute_receive {:transition, "1571", _state_name, _expected}
  end

  test "the dispatcher keeps a ticket a stored merge only mentions in passing", %{store: store} do
    assert {:ok, _} = RecentMergeStore.upsert(merge_closing("Closes #1570, #1571\n> Closes #1572"), store)

    issues = [
      %Issue{id: "issue-1571", identifier: "1571", state: "Todo"},
      %Issue{id: "issue-1572", identifier: "1572", state: "Todo"}
    ]

    parent = self()

    {_state, candidates} =
      Dispatcher.reconcile_merged_tickets(%State{}, issues,
        recent_merges_fun: fn -> RecentMergeStore.list(store) end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn identifier, _state_name, _expected ->
          send(parent, {:transition, identifier})
          :ok
        end,
        resume_blockees_fun: fn state, _identifier -> state end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
      )

    assert candidates == issues
    refute_receive {:transition, _identifier}
    refute_receive {:alert, _topic, _opts}
  end

  defp merge_closing(body) do
    event = %{
      "id" => "evt-1600",
      "type" => "PullRequestEvent",
      "created_at" => "2026-07-12T17:59:00Z",
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 1600,
          "merged" => true,
          "merged_at" => "2026-07-12T17:59:00Z",
          "title" => "Ship it",
          "body" => body,
          "html_url" => "https://github.com/owner/repo/pull/1600",
          "head" => %{"ref" => "aiur/1570-ship-it", "sha" => "head-1600"}
        }
      }
    }

    assert {:ok, merge} = RecentMerge.from_github_event(event, live?: false, now: @now)
    assert %RecentMerge{} = merge
    merge
  end
end
