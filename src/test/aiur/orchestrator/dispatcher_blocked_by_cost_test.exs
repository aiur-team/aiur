defmodule Aiur.Orchestrator.DispatcherBlockedByCostTest do
  @moduledoc """
  Regression for #2714: after #2710 the dispatch gate re-read
  `/dependencies/blocked_by` unconditionally for every held dependent on every
  pass, and refreshed each one with an `issue_by_id` read first. On Khala the two
  were two thirds of the daemon's core spend.

  These tests run the production chain (default hydrator, `Client`, `Transport`)
  against a GitHub double and count the requests it receives.
  """

  use Aiur.TestSupport

  alias Aiur.GitHub.{CycleFetchCache, Issues, OpenIssueSnapshot, Quota, ResourceStore, WriteThrough}
  alias Aiur.Orchestrator.{CommentWake, Dispatcher, State}

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @blocker 53
  @repository_url "https://api.github.com/repos/owner/repo"

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)

    previous_options = Application.get_env(:aiur, :github_transport_test_options)
    previous_quota = Application.get_env(:aiur, :github_quota_server)
    previous_budget_enabled = Application.get_env(:aiur, :github_budget_enabled?)
    previous_max_age = Application.get_env(:aiur, :blocked_by_max_age_ms)
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_cached_token = :persistent_term.get(@token_cache_key, :unset)
    workflow_path = Workflow.workflow_file_path()
    original_workflow = File.read!(workflow_path)

    quota = start_supervised!({Quota, name: nil, emit_fun: fn _name, _opts -> :ok end})
    Application.put_env(:aiur, :github_transport_test_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:aiur, :github_quota_server, quota)
    Application.put_env(:aiur, :github_budget_enabled?, false)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(workflow_path,
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym",
      max_concurrent_agents: 4,
      tracker_terminal_states: ["Done", "Cancelled", "Canceled"]
    )

    ResourceStore.reset()
    OpenIssueSnapshot.reset()

    on_exit(fn ->
      ResourceStore.reset()
      OpenIssueSnapshot.reset()
      File.write!(workflow_path, original_workflow)
      restore_app_env(:github_transport_test_options, previous_options)
      restore_app_env(:github_quota_server, previous_quota)
      restore_app_env(:github_budget_enabled?, previous_budget_enabled)
      restore_app_env(:blocked_by_max_age_ms, previous_max_age)
      restore_env("GITHUB_TOKEN", previous_token)

      case previous_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    :ok
  end

  test "N held dependents across K passes cost N blocked_by reads and no issue_by_id reads" do
    dependents = ~w(14 15 16)
    passes = 5

    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    for _pass <- 1..passes, id <- dependents do
      state = run_pass(candidate(id))
      assert state.dispatch_declines[id] == :dependency
      refute Map.has_key?(state.running, id)
    end

    # One edge read per dependent in total: the first one proved blocker #53
    # open and deposited it, and every later pass read both from the store.
    assert blocked_by_reads() |> Enum.sort() == Enum.sort(dependents)

    # A held dependent is never refreshed: the dependency gate runs before the
    # `issue_by_id` refresh and its `dispatch_authorization` read.
    refute_received {:issue_fetch, _ids}
    refute_received {:github, _path}
  end

  test "a blocker closing in the :issue store releases its dependent on the next pass with no blocked_by read" do
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    held = run_pass(candidate("14"))
    assert held.dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    # The tracker poll (or a webhook, or Aiur's own close) records the close.
    ResourceStore.put_resource(
      ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"),
      blocker_body("closed", [], "2026-09-18T03:00:00Z"),
      source: :poll,
      version: "2026-09-18T03:00:00Z"
    )

    released = run_pass(candidate("14"), held)

    assert_receive {:agent_runner_run, dispatched, _recipient, _opts}
    assert dispatched.id == "14"
    assert Map.has_key?(released.running, "14")
    assert blocked_by_reads() == []
  end

  test "a blocker whose :issue record is older than the bound forces one re-read, which refreshes it" do
    Application.put_env(:aiur, :blocked_by_max_age_ms, 100)
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == []

    Process.sleep(150)

    # The edges are fresh again (an `issue_dependencies` webhook re-deposited
    # them), so only the blocker's aged `:issue` record can force this read.
    edges_key = ResourceStore.key(:issue_blocked_by, "owner", "repo", "14")
    ResourceStore.put_resource(edges_key, ResourceStore.data(edges_key), source: :webhook)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    # That read proved #53 current again, so the next pass is free.
    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == []
  end

  # The fail-closed bound. The held edge list is empty and fresh, so within the
  # bound it is served; a blocker then added on GitHub's side, with no Aiur write
  # and no webhook delivery, must hold the dependent once the list is older than
  # `BoundedBlockedBy.max_age_ms/0` (15 minutes by default; 100 ms here).
  test "a blocker added on GitHub's side with no Aiur write holds dispatch once the edge list is older than the bound" do
    Application.put_env(:aiur, :blocked_by_max_age_ms, 100)

    ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", "14"), [], source: :fetch)
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:todo"}])] end)

    Process.sleep(150)

    state = run_pass(candidate("14"))

    assert state.dispatch_declines["14"] == :dependency
    refute Map.has_key?(state.running, "14")
    refute_received {:agent_runner_run, _dispatched, _recipient, _opts}
    assert blocked_by_reads() == ["14"]
  end

  test "a cross-repository blocker takes its state from its own repository's :issue record" do
    # A same-numbered issue in the tracker repository is closed. It must not
    # stand in for the open blocker in `other/lib`.
    ResourceStore.put_resource(
      ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"),
      blocker_body("closed", []),
      source: :poll
    )

    foreign = Map.put(blocker_body("open", []), "repository_url", "https://api.github.com/repos/other/lib")
    stub_github(fn _number -> [foreign] end)

    for _pass <- 1..3 do
      assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    end

    assert blocked_by_reads() == ["14"]
    assert %{"state" => "open"} = ResourceStore.data(ResourceStore.key(:issue, "other", "lib", "#{@blocker}"))
    assert %{"state" => "closed"} = ResourceStore.data(ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"))
  end

  test "a blocked_by read never rolls back a newer :issue record" do
    # The store already holds #53 closed at 03:00. A lagging dependencies read
    # still embeds it open at 02:00.
    ResourceStore.put_resource(
      ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"),
      blocker_body("closed", [], "2026-09-18T03:00:00Z"),
      source: :webhook,
      version: "2026-09-18T03:00:00Z"
    )

    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]
    assert %{"state" => "closed"} = ResourceStore.data(ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"))

    # The next pass reads the held edge and the newer record, and dispatches.
    released = run_pass(candidate("14"))
    assert Map.has_key?(released.running, "14")
    assert blocked_by_reads() == []
  end

  test "a blocker closed on GitHub with no running entry and no store write releases its dependent after the next poll, for one read" do
    open_blocker = [blocker_body("open", [%{"name" => "sym:human-review"}])]
    stub_github(fn _number -> open_blocker end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    # Closed by a manual close, or by a PR whose branch is not `aiur/53`: no
    # agent, no mutation, no webhook. Only the open-issue poll can see it.
    Process.sleep(2)
    assert {:ok, _candidates, _cache} = poll_open_issues()

    closed_blocker = [blocker_body("closed", [], "2026-09-18T03:00:00Z")]
    stub_github(fn _number -> closed_blocker end)

    released = run_pass(candidate("14"))

    assert_receive {:agent_runner_run, dispatched, _recipient, _opts}
    assert dispatched.id == "14"
    assert Map.has_key?(released.running, "14")
    assert blocked_by_reads() == ["14"]
    assert %{"state" => "closed"} = ResourceStore.data(ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"))

    # The re-read wrote the close back, so later passes need no read.
    run_pass(candidate("14"), released)
    assert blocked_by_reads() == []
  end

  test "a failed open-issue poll gives no close signal" do
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    Process.sleep(2)
    assert {:error, _reason} = poll_open_issues(500)
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == []
  end

  test "an open-issue listing taken before the blocker's record gives no close signal" do
    # The listing predates the blocker (it opened, or reopened, afterwards).
    assert {:ok, _candidates, _cache} = poll_open_issues()
    Process.sleep(2)

    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    for _pass <- 1..3 do
      assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    end

    assert blocked_by_reads() == ["14"]
  end

  test "a label write does not make a blocker's old state look fresh" do
    Application.put_env(:aiur, :blocked_by_max_age_ms, 100)
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    Process.sleep(150)

    # Aiur relabels #53 and refreshes the edges: both entries have a new
    # `fetched_at_ms`, but #53's `"state"` is still 150 ms old.
    WriteThrough.issue_labels(@blocker, [%{"name" => "sym:rework"}])
    edges_key = ResourceStore.key(:issue_blocked_by, "owner", "repo", "14")
    ResourceStore.put_resource(edges_key, ResourceStore.data(edges_key), source: :webhook)

    assert %{"labels" => [%{"name" => "sym:rework"}]} =
             ResourceStore.data(ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"))

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]
  end

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
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/owner/repo/issues"
      Req.Test.json(conn, [%{"number" => 99, "html_url" => "u99", "state" => "open", "labels" => []}])
    end)

    assert {:ok, _candidates} = Issues.fetch_candidate_issues()
    assert {:ok, open, _taken_at_ms} = OpenIssueSnapshot.fetch("owner", "repo", 60_000)
    assert MapSet.to_list(open) == ["99"]
  end

  test "a snapshot written by a short-lived process outlives it" do
    # `IssueContext` and the comment wake list open issues from processes that
    # exit right after; the table must not belong to them.
    Task.async(fn -> OpenIssueSnapshot.put("owner", "repo", [7]) end) |> Task.await()

    assert {:ok, open, _taken_at_ms} = OpenIssueSnapshot.fetch("owner", "repo", 60_000)
    assert MapSet.to_list(open) == ["7"]
  end

  # Takes each blocked refresh as it arrives (they run one after another in
  # one task) and releases it, until none arrives within 200 ms.
  defp collect_refreshes(acc \\ []) do
    receive do
      {:refresh, identifier, pid} ->
        send(pid, :release)
        collect_refreshes([{identifier, pid} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  defp run_pass(%Issue{} = issue, state \\ %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}) do
    test_pid = self()

    runner = fn dispatched, recipient, opts ->
      send(test_pid, {:agent_runner_run, dispatched, recipient, opts})
      :ok
    end

    CycleFetchCache.start_cycle()

    try do
      Dispatcher.dispatch_issue(state, issue, nil, nil,
        issue_fetcher: fn ids ->
          send(test_pid, {:issue_fetch, ids})
          {:ok, Enum.map(ids, &%{issue | id: &1})}
        end,
        runner: runner
      )
    after
      CycleFetchCache.end_cycle()
    end
  end

  defp candidate(id) do
    %Issue{id: id, identifier: id, title: "dependent #{id}", state: "todo", selected_backend: "codex"}
  end

  defp blocker_body(state, labels, updated_at \\ "2026-09-18T02:00:00Z") do
    %{
      "number" => @blocker,
      "html_url" => "https://github.com/owner/repo/issues/#{@blocker}",
      "repository_url" => @repository_url,
      "state" => state,
      "labels" => labels,
      "updated_at" => updated_at
    }
  end

  # `routes` answers other paths: `%{path => fun(conn) -> conn}`. Each one is
  # reported as `{:routed, path}`; any other path is a failure the tests refute.
  defp stub_github(blockers_for, routes \\ %{}) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case Regex.run(~r{^/repos/owner/repo/issues/(\d+)/dependencies/blocked_by$}, conn.request_path) do
        [_, number] ->
          send(test_pid, {:blocked_by_read, number, Plug.Conn.get_req_header(conn, "if-none-match")})
          Req.Test.json(conn, blockers_for.(number))

        nil ->
          route(conn, routes, test_pid)
      end
    end)
  end

  defp route(conn, routes, test_pid) do
    case Map.fetch(routes, conn.request_path) do
      {:ok, respond} ->
        send(test_pid, {:routed, conn.request_path})
        respond.(conn)

      :error ->
        send(test_pid, {:github, conn.request_path})
        Plug.Conn.send_resp(conn, 500, "unexpected request")
    end
  end

  # One tick of the candidate poll, through the real conditional reader. The
  # listing names only issue #99 (open, no `agent:*` label), so it needs no
  # authorization reads, and #53 is absent: GitHub has closed it.
  defp poll_open_issues(status \\ 200) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/owner/repo/issues"

      if status == 200 do
        Req.Test.json(conn, [%{"number" => 99, "html_url" => "u99", "state" => "open", "labels" => []}])
      else
        Plug.Conn.send_resp(conn, status, "boom")
      end
    end)

    Issues.fetch_candidate_issues_conditional(%{})
  end

  # Drains the blocked_by reads received so far. Every one of them must be
  # unconditional: a conditional read of this endpoint cannot see a blocker
  # change (#2550, #2552).
  defp blocked_by_reads(acc \\ []) do
    receive do
      {:blocked_by_read, number, validator} ->
        assert validator == []
        blocked_by_reads([number | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
