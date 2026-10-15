defmodule Aiur.DispatcherBlockedByCostSupport do
  @moduledoc false
  # Shared GitHub double, setup and helpers for the dispatcher blocked_by cost tests.
  # The Req.Test stub is registered under this module's name.

  import Aiur.TestSupport, only: [write_workflow_file!: 2, restore_env: 2]
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Aiur.GitHub.{CycleFetchCache, Issues, OpenIssueSnapshot, Quota, ResourceStore}
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{Dispatcher, State}
  alias Aiur.Workflow

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @blocker 53
  @repository_url "https://api.github.com/repos/owner/repo"
  @max_age_ms :timer.minutes(15)

  defmacro __using__(_opts) do
    quote do
      use Aiur.TestSupport

      import Aiur.DispatcherBlockedByCostSupport

      alias Aiur.GitHub.{CycleFetchCache, Issues, OpenIssueSnapshot, Quota, ResourceStore, WriteThrough}
      alias Aiur.Orchestrator.{CommentWake, Dispatcher, State}

      @blocker 53

      setup_all {Aiur.DispatcherBlockedByCostSupport, :suspend_orchestrator}
      setup {Aiur.DispatcherBlockedByCostSupport, :github_double}
    end
  end

  @doc false
  def suspend_orchestrator(_context) do
    # Keep the live poller out of the process-owned double until fixture cleanup.
    orchestrator = Process.whereis(Orchestrator)
    :ok = :sys.suspend(orchestrator)
    on_exit(fn -> :ok = :sys.resume(orchestrator) end)
    :ok
  end

  @doc false
  def github_double(_context) do
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
    Application.put_env(:aiur, :blocked_by_max_age_ms, @max_age_ms)
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

  # Takes each blocked refresh as it arrives (they run one after another in
  # one task) and releases it, until none arrives within 200 ms.
  def collect_refreshes(acc \\ []) do
    receive do
      {:refresh, identifier, pid} ->
        send(pid, :release)
        collect_refreshes([{identifier, pid} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  def eventually(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  def run_pass(%Issue{} = issue, state \\ %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}) do
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

  def candidate(id) do
    %Issue{id: id, identifier: id, title: "dependent #{id}", state: "todo", selected_backend: "codex"}
  end

  def blocker_body(state, labels, updated_at \\ "2026-09-18T02:00:00Z") do
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
  def stub_github(blockers_for, routes \\ %{}) do
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

  def route(conn, routes, test_pid) do
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
  def poll_open_issues(status \\ 200) do
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
  def blocked_by_reads(acc \\ []) do
    receive do
      {:blocked_by_read, number, validator} ->
        assert validator == []
        blocked_by_reads([number | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Age only the fact under test; ordinary dispatch passes retain a wide freshness window.
  def age_resource(key, field) do
    [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
    :ets.insert(ResourceStore.Table, {key, Map.update!(entry, field, &(&1 - @max_age_ms - 1))})
  end

  def restore_app_env(key, nil), do: Application.delete_env(:aiur, key)

  def restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
