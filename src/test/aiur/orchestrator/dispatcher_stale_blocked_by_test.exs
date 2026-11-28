defmodule Aiur.Orchestrator.DispatcherStaleBlockedByTest do
  @moduledoc """
  Regression for #8196: a populated candidate blocker list can be stale after
  GitHub removes an edge without delivering a webhook. The dispatch gate must
  route that list through the bounded freshness check rather than trust the
  candidate snapshot or force a remote read on every dispatch pass.

  This test runs that chain end to end — no injected hydrator, the real
  `Client` and `Transport` — against a GitHub double that returns the current
  empty blocker list after the cached edge record is aged past its freshness
  bound.
  """

  use Aiur.TestSupport

  defmodule TodoClaimTracker do
    def update_issue_state(_issue_id, _state, _opts), do: :ok
  end

  alias Aiur.GitHub.{BoundedBlockedBy, Quota, ResourceStore}
  alias Aiur.Orchestrator.{Dispatcher, State}

  @token_cache_key {Aiur.GitHub.Access.Token, :resolved_token}

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)

    previous_options = Application.get_env(:aiur, :github_transport_test_options)
    previous_quota = Application.get_env(:aiur, :github_quota_server)
    previous_budget_enabled = Application.get_env(:aiur, :github_budget_enabled?)
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
      restore_env("GITHUB_TOKEN", previous_token)

      case previous_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    :ok
  end

  test "a removed edge in a populated candidate list no longer holds dispatch on the next tick" do
    # The stored list from the dispatch tick before the blocker merged: the
    # blocker is open, in human review, and the edge record is past its freshness bound.
    key = ResourceStore.key_for_repo(:issue_blocked_by, "owner/repo", 14)

    held = [
      %{"number" => 53, "html_url" => "u53", "state" => "open", "labels" => [%{"name" => "sym:human-review"}]}
    ]

    ResourceStore.put_resource(key, held, source: :fetch, etag: ~s("e1"))
    [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)

    :ets.insert(
      ResourceStore.Table,
      {key, Map.update!(entry, :fetched_at_ms, &(&1 - BoundedBlockedBy.max_age_ms() - 1))}
    )

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/owner/repo/issues/14/dependencies/blocked_by"
      validator = Plug.Conn.get_req_header(conn, "if-none-match")
      send(test_pid, {:blocked_by_read, validator})

      conn = Plug.Conn.put_resp_header(conn, "etag", ~s("e1"))

      case validator do
        [] -> Req.Test.json(conn, [])
        _conditional -> Plug.Conn.send_resp(conn, 304, "")
      end
    end)

    candidate = %Issue{
      id: "14",
      identifier: "14",
      title: "dependent whose last blocker just merged",
      state: "todo",
      selected_backend: "codex",
      blocked_by: [%{id: "53", identifier: "53", state: "human-review", url: "u53"}]
    }

    runner = fn dispatched, recipient, opts ->
      send(test_pid, {:agent_runner_run, dispatched, recipient, opts})
      :ok
    end

    next_state =
      Dispatcher.dispatch_issue(
        %State{max_concurrent_agents: 4, effective_concurrent_agents: 4},
        candidate,
        nil,
        nil,
        issue_fetcher: fn [id] -> {:ok, [%{candidate | id: id}]} end,
        todo_dispatch_tracker: TodoClaimTracker,
        # PR-head capture is unrelated to dependency hydration and must not hit its HTTP double.
        rework_head_fetcher: fn _identifier -> {:ok, nil} end,
        runner: runner
      )

    # The gate asked GitHub, unconditionally, instead of serving the held body.
    assert_received {:blocked_by_read, []}

    receive_barrier({:agent_runner_run, dispatched, _recipient, _opts})
    assert dispatched.id == candidate.id
    assert Map.has_key?(next_state.running, candidate.id)
    refute Map.get(next_state.dispatch_declines, candidate.id) == :dependency

    # The empty result replaced the stale list, so later readers see no edge.
    assert ResourceStore.data(key) == []
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
