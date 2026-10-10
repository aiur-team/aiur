defmodule Aiur.Orchestrator.Dispatcher.BlockedByCostCacheTest do
  @moduledoc "Poll and merge close-signal cases of the #2714 regression; see BlockedByCostReadsTest."

  use Aiur.DispatcherBlockedByCostSupport

  test "a merged PR refreshes every other issue it closes, and their dependents dispatch with no blocked_by read" do
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    held = run_pass(candidate("14"))
    assert held.dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    # PR `aiur/60-…` closes #60 (its branch ticket) and #53.
    closed = blocker_body("closed", [], "2026-09-18T03:00:00Z")

    stub_github(fn _number -> [closed] end, %{
      "/repos/owner/repo/issues/#{@blocker}" => &Req.Test.json(&1, closed)
    })

    CommentWake.mark_pr_merged_issue_done(%State{}, "60",
      pr_body: "Closes #60\nFixes #53",
      target_state: "done",
      update_issue_state_fun: fn "60", "done" -> :ok end,
      clear_session_handle_fun: fn _identifier -> :ok end,
      observe_membership_fun: fn _identity, _lifecycle -> :ok end,
      set_terminal_verification_pending_fun: fn _identity, _pending? -> :ok end,
      mark_reconciled_fun: fn _identity -> :ok end,
      terminate_running_issue_fun: fn state, _issue_id, _cleanup? -> state end,
      resume_blockees_fun: fn state, _identifier -> state end,
      merger_allowed_fun: fn _login -> true end,
      emit_alert_fun: fn _name, _opts -> :ok end,
      repo_fun: fn -> "owner/repo" end
    )

    # The refresh runs off the calling process, so wait for its write.
    assert_receive {:routed, "/repos/owner/repo/issues/53"}, 2_000
    assert eventually(fn -> match?(%{"state" => "closed"}, ResourceStore.data(ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"))) end)
    refute_received {:routed, "/repos/owner/repo/issues/60"}

    released = run_pass(candidate("14"), held)
    assert Map.has_key?(released.running, "14")
    assert blocked_by_reads() == []
    refute_received {:github, _path}
  end

  test "an epic PR refreshes at most 10 closing issues, off the calling process" do
    test_pid = self()
    references = Enum.map(101..140, &"Closes ##{&1}")

    refresh_issue_fun = fn identifier ->
      send(test_pid, {:refresh, identifier, self()})

      receive do
        :release -> :ok
      end
    end

    merge =
      Task.async(fn ->
        CommentWake.mark_pr_merged_issue_done(%State{}, "100",
          pr_body: Enum.join(["Closes #100" | references], "\n"),
          target_state: "done",
          refresh_issue_fun: refresh_issue_fun,
          update_issue_state_fun: fn "100", "done" -> :ok end,
          clear_session_handle_fun: fn _identifier -> :ok end,
          observe_membership_fun: fn _identity, _lifecycle -> :ok end,
          set_terminal_verification_pending_fun: fn _identity, _pending? -> :ok end,
          mark_reconciled_fun: fn _identity -> :ok end,
          terminate_running_issue_fun: fn state, _issue_id, _cleanup? -> state end,
          resume_blockees_fun: fn state, _identifier -> state end,
          merger_allowed_fun: fn _login -> true end,
          emit_alert_fun: fn _name, _opts -> :ok end,
          repo_fun: fn -> "owner/repo" end
        )
      end)

    # Every refresh blocks until released, yet the merge path returns: the
    # reads never run on the process that handles the merge.
    assert {:ok, %State{}} = Task.yield(merge, 1_000) || Task.shutdown(merge, :brutal_kill)

    refreshed = collect_refreshes()
    assert length(refreshed) == 10
    assert Enum.map(refreshed, &elem(&1, 0)) == Enum.map(101..110, &to_string/1)
  end

  test "the unconditional open-issue listing records the close signal too" do
    Req.Test.stub(Aiur.DispatcherBlockedByCostSupport, fn conn ->
      assert conn.request_path == "/repos/owner/repo/issues"
      Req.Test.json(conn, [%{"number" => 99, "html_url" => "u99", "state" => "open", "labels" => []}])
    end)

    assert {:ok, _candidates} = Issues.fetch_candidate_issues()
    assert {:ok, open, _taken_at_ms} = OpenIssueSnapshot.fetch("owner", "repo", 60_000)
    assert MapSet.to_list(open) == ["99"]
  end

  # #2957: the open-issue listing is intake's second producer. It offers only
  # issues created in the last 24 hours, carrying the API's numeric author id,
  # type and App provenance — never the title or body.
  test "the open-issue listing offers fresh issues to allowed-contributor intake" do
    fresh = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
    stale = DateTime.utc_now() |> DateTime.add(-3 * 86_400) |> DateTime.to_iso8601()

    Req.Test.stub(Aiur.DispatcherBlockedByCostSupport, fn conn ->
      Req.Test.json(conn, [
        %{"number" => 98, "state" => "open", "labels" => [], "created_at" => fresh, "performed_via_github_app" => nil, "user" => %{"id" => 42, "login" => "alice", "type" => "User"}},
        # No provenance key at all: unknown, so intake must see it as App-created.
        %{"number" => 95, "state" => "open", "labels" => [], "created_at" => fresh, "user" => %{"id" => 42, "login" => "alice", "type" => "User"}},
        %{"number" => 97, "state" => "open", "labels" => [], "created_at" => stale, "user" => %{"id" => 42, "login" => "alice", "type" => "User"}},
        %{
          "number" => 96,
          "state" => "open",
          "labels" => [],
          "created_at" => fresh,
          "user" => %{"id" => 43, "login" => "bob", "type" => "User"},
          "performed_via_github_app" => %{"id" => 1}
        }
      ])
    end)

    true = Process.register(self(), Aiur.AllowedContributors)
    on_exit(fn -> if Process.whereis(Aiur.AllowedContributors), do: Process.unregister(Aiur.AllowedContributors) end)

    assert {:ok, _candidates} = Issues.fetch_candidate_issues()
    Process.unregister(Aiur.AllowedContributors)

    assert_received {:"$gen_cast", {:observe, %{number: 98, author_id: 42, author_type: "User", via_app?: false, source: :poll}}}
    assert_received {:"$gen_cast", {:observe, %{number: 96, via_app?: true}}}
    assert_received {:"$gen_cast", {:observe, %{number: 95, via_app?: true}}}
    refute_received {:"$gen_cast", {:observe, %{number: 97}}}
  end

  test "a snapshot written by a short-lived process outlives it" do
    # `IssueContext` and the comment wake list open issues from processes that
    # exit right after; the table must not belong to them.
    Task.async(fn -> OpenIssueSnapshot.put("owner", "repo", [7]) end) |> Task.await()

    assert {:ok, open, _taken_at_ms} = OpenIssueSnapshot.fetch("owner", "repo", 60_000)
    assert MapSet.to_list(open) == ["7"]
  end
end
