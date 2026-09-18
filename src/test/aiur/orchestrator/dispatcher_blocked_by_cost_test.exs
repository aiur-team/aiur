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

  alias Aiur.GitHub.{CycleFetchCache, Quota, ResourceStore}
  alias Aiur.Orchestrator.{Dispatcher, State}

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

    on_exit(fn ->
      ResourceStore.reset()
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

  defp stub_github(blockers_for) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case Regex.run(~r{^/repos/owner/repo/issues/(\d+)/dependencies/blocked_by$}, conn.request_path) do
        [_, number] ->
          send(test_pid, {:blocked_by_read, number, Plug.Conn.get_req_header(conn, "if-none-match")})
          Req.Test.json(conn, blockers_for.(number))

        nil ->
          send(test_pid, {:github, conn.request_path})
          Plug.Conn.send_resp(conn, 500, "unexpected request")
      end
    end)
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
