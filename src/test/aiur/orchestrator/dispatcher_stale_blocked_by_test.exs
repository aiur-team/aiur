defmodule Aiur.Orchestrator.DispatcherStaleBlockedByTest do
  @moduledoc """
  Regression for #2709: a dependent held at `dispatch_decline=:dependency`
  after every blocker closed.

  #2553 made `Issues.hydrate_blocked_by/1` revalidate unconditionally, but the
  dispatch gate never reached that arity. `Dispatcher.default_blocked_by_hydrator/1`
  -> `Tracker.hydrate_blocked_by/1` -> `Client.hydrate_blocked_by/1`, whose
  `opts \\\\ []` default forwarded to `Issues.hydrate_blocked_by(issue, [])`,
  and without `revalidate: true` the store answered with the held body and no
  request. Every dispatcher test injects `:blocked_by_hydrator`, and the #2553
  tests call `Issues.hydrate_blocked_by/2` with `revalidate: true` directly, so
  neither saw the production chain.

  This test runs that chain end to end — no injected hydrator, the real
  `Client` and `Transport` — against a GitHub double that answers `304` to any
  conditional read (the endpoint's ETag tracks the blocked issue, not the
  blocker state it embeds) and the truth to an unconditional one.
  """

  use Aiur.TestSupport

  alias Aiur.GitHub.{Quota, ResourceStore}
  alias Aiur.Orchestrator.{Dispatcher, State}

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

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

  test "a blocker that closed after the list was stored no longer holds the dependent on the next tick" do
    # The stored list from the dispatch tick before the blocker merged: the
    # blocker is open, in human review, and the entry carries a validator.
    key = ResourceStore.key_for_repo(:issue_blocked_by, "owner/repo", 14)

    held = [
      %{"number" => 53, "html_url" => "u53", "state" => "open", "labels" => [%{"name" => "sym:human-review"}]}
    ]

    ResourceStore.put_resource(key, held, source: :fetch, etag: ~s("e1"))

    closed = [
      %{
        "number" => 53,
        "html_url" => "u53",
        "state" => "closed",
        "labels" => [],
        "updated_at" => "2026-09-18T02:07:50Z"
      }
    ]

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/owner/repo/issues/14/dependencies/blocked_by"
      validator = Plug.Conn.get_req_header(conn, "if-none-match")
      send(test_pid, {:blocked_by_read, validator})

      conn = Plug.Conn.put_resp_header(conn, "etag", ~s("e1"))

      case validator do
        [] -> Req.Test.json(conn, closed)
        _conditional -> Plug.Conn.send_resp(conn, 304, "")
      end
    end)

    candidate = %Issue{
      id: "14",
      identifier: "14",
      title: "dependent whose last blocker just merged",
      state: "todo",
      selected_backend: "codex"
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
        runner: runner
      )

    # The gate asked GitHub, unconditionally, instead of serving the held body.
    assert_received {:blocked_by_read, []}

    assert_receive {:agent_runner_run, dispatched, _recipient, _opts}
    assert dispatched.id == candidate.id
    assert Map.has_key?(next_state.running, candidate.id)
    refute Map.get(next_state.dispatch_declines, candidate.id) == :dependency

    # And the store now holds the truth, so a later reader is not misled either.
    assert [%{"number" => 53, "state" => "closed"}] = ResourceStore.data(key)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
