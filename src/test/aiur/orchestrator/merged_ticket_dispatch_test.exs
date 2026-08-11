defmodule Aiur.Orchestrator.MergedTicketDispatchTest do
  @moduledoc """
  Covers the dispatcher call site itself: the poll cycle reconciles merged
  tickets against the real `Aiur.RecentMergeStore` before the surviving
  candidates reach state sync, capacity alerts, and dispatch.
  """

  use ExUnit.Case, async: false

  alias Aiur.{Issue, RecentMerge, RecentMergeStore}
  alias Aiur.Orchestrator.{Dispatcher, State}

  @now ~U[2026-07-12 18:00:00Z]

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-merged-dispatch-#{System.unique_integer([:positive])}")

    {:ok, pid} =
      RecentMergeStore.start_link(name: RecentMergeStore, state_dir: dir, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "the dispatcher drops a ticket a stored merged PR closed and keeps the rest" do
    assert {:ok, _} = RecentMergeStore.upsert(merge_closing("Closes #1570"))

    closed = %Issue{id: "issue-1570", identifier: "1570", state: "Todo"}
    open = %Issue{id: "issue-1571", identifier: "1571", state: "Todo"}
    parent = self()

    {_state, candidates} =
      Dispatcher.reconcile_merged_tickets(%State{}, [closed, open],
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

  test "the dispatcher keeps a ticket a stored merge only mentions in passing" do
    assert {:ok, _} = RecentMergeStore.upsert(merge_closing("Closes #1570, #1571\n> Closes #1572"))

    issues = [
      %Issue{id: "issue-1571", identifier: "1571", state: "Todo"},
      %Issue{id: "issue-1572", identifier: "1572", state: "Todo"}
    ]

    parent = self()

    {_state, candidates} =
      Dispatcher.reconcile_merged_tickets(%State{}, issues,
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
