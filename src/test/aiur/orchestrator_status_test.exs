defmodule Aiur.OrchestratorStatusTest do
  use Aiur.TestSupport

  alias Aiur.Codex.CodingAgent, as: CodexCodingAgent

  defmodule StartupCleanupLinearClient do
    def fetch_candidate_issues, do: {:ok, []}

    def fetch_issues_by_states(states), do: fetch_issues_by_states(states, [])

    def fetch_issues_by_states(_states, opts) do
      notify({:startup_cleanup_fetch_issues_by_states, opts})
      {:error, {:linear_api_status, 401}}
    end

    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

    defp notify(message) do
      case Application.get_env(:aiur, :startup_cleanup_test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  defmodule StartupCleanupGitHubClient do
    def preflight_auth, do: :ok
    def fetch_candidate_issues, do: {:ok, []}

    def fetch_issues_by_states(states), do: fetch_issues_by_states(states, [])

    def fetch_issues_by_states(states, opts) do
      notify({:github_startup_cleanup_fetch_issues_by_states, states, opts})
      {:ok, []}
    end

    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

    defp notify(message) do
      case Application.get_env(:aiur, :startup_cleanup_test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  defp normalize(event), do: CodexCodingAgent.normalize_event(event)

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  defp running_entry(issue_id, identifier, status, pid \\ self(), worker_host \\ nil, title \\ nil) do
    %{
      pid: pid,
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress", title: title},
      worker_host: worker_host,
      control: %{
        can_interrupt: true,
        safe_checkpoints: [:notification],
        status: status
      },
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  test "snapshot returns :timeout when snapshot server is unresponsive" do
    server_name = Module.concat(__MODULE__, :UnresponsiveSnapshotServer)
    parent = self()

    pid =
      spawn(fn ->
        Process.register(self(), server_name)
        send(parent, :snapshot_server_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :snapshot_server_ready, 1_000
    assert Orchestrator.snapshot(server_name, 10) == :timeout

    send(pid, :stop)
  end

  test "startup terminal cleanup skips Linear fetch when Linear token is missing" do
    previous_linear_client = Application.get_env(:aiur, :linear_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: nil,
        tracker_project_slug: "project",
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :linear_client_module, StartupCleanupLinearClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      log =
        capture_log([level: :debug], fn ->
          assert %Orchestrator.State{} =
                   Orchestrator.run_terminal_workspace_cleanup_for_test(%Orchestrator.State{})
        end)

      refute_received {:startup_cleanup_fetch_issues_by_states, _opts}
      assert log =~ "Skipping startup terminal workspace cleanup: :missing_linear_api_token"
      refute log =~ "[warning]"
      refute log =~ "[error]"
    after
      restore_application_env(:linear_client_module, previous_linear_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
    end
  end

  test "startup terminal cleanup preserves full config preflight after Linear auth is present" do
    previous_linear_client = Application.get_env(:aiur, :linear_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: "token",
        tracker_project_slug: "project",
        agent_kind: "bogus",
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :linear_client_module, StartupCleanupLinearClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      log =
        capture_log([level: :debug], fn ->
          assert %Orchestrator.State{} =
                   Orchestrator.run_terminal_workspace_cleanup_for_test(%Orchestrator.State{})
        end)

      refute_received {:startup_cleanup_fetch_issues_by_states, _opts}
      assert log =~ "Skipping startup terminal workspace cleanup: {:unsupported_agent_kind, \"bogus\"}"
      assert log =~ "[warning]"
    after
      restore_application_env(:linear_client_module, previous_linear_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
    end
  end

  test "startup terminal cleanup suppresses Linear auth failure logs" do
    previous_linear_client = Application.get_env(:aiur, :linear_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: "invalid-token",
        tracker_project_slug: "project",
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :linear_client_module, StartupCleanupLinearClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      log =
        capture_log([level: :debug], fn ->
          assert %Orchestrator.State{} =
                   Orchestrator.run_terminal_workspace_cleanup_for_test(%Orchestrator.State{})
        end)

      assert_received {:startup_cleanup_fetch_issues_by_states, opts}
      assert Keyword.fetch!(opts, :quiet_auth_errors?) == true
      assert log =~ "Skipping startup terminal workspace cleanup; failed to fetch terminal issues: {:linear_api_status, 401}"
      refute log =~ "[warning]"
      refute log =~ "[error]"
    after
      restore_application_env(:linear_client_module, previous_linear_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
    end
  end

  test "GitHub startup terminal cleanup does not depend on Linear auth" do
    previous_github_client = Application.get_env(:aiur, :github_client_module)
    previous_linear_client = Application.get_env(:aiur, :linear_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)
    previous_github_token = System.get_env("GITHUB_TOKEN")

    try do
      System.put_env("GITHUB_TOKEN", "gh-test-token")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_terminal_states: ["done"],
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :github_client_module, StartupCleanupGitHubClient)
      Application.put_env(:aiur, :linear_client_module, StartupCleanupLinearClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      assert %Orchestrator.State{} =
               Orchestrator.run_terminal_workspace_cleanup_for_test(%Orchestrator.State{})

      assert_received {:github_startup_cleanup_fetch_issues_by_states, ["done"], opts}
      assert Keyword.fetch!(opts, :quiet_auth_errors?) == true
      refute_received {:startup_cleanup_fetch_issues_by_states, _opts}
    after
      restore_application_env(:github_client_module, previous_github_client)
      restore_application_env(:linear_client_module, previous_linear_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
      restore_env("GITHUB_TOKEN", previous_github_token)
    end
  end

  test "snapshot renders an issue's pending operator messages without crashing" do
    orchestrator_name = Module.concat(__MODULE__, :PendingOperatorMsgOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    {store, _item} =
      Aiur.AgentQueueStore.enqueue(
        Aiur.AgentQueueStore.new(),
        Aiur.AgentQueue.operator_message("MT-OP", "hello operator text")
      )

    entry =
      "issue-op"
      |> running_entry("MT-OP", :working)
      |> Map.merge(%{
        codex_app_server_pid: nil,
        last_codex_timestamp: nil,
        last_codex_message: nil,
        last_codex_event: nil
      })

    :sys.replace_state(pid, fn state ->
      %{state | queue_store: store, running: %{"issue-op" => entry}}
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)

    # Regression: rendering the visible operator message used to run get_in/2 on
    # an %AgentQueueItem{} struct, which crashed the whole Orchestrator GenServer
    # (structs don't implement Access). The struct's body map is reached directly now.
    refute snapshot == :timeout
    assert Process.alive?(pid)
    assert inspect(snapshot) =~ "hello operator text"
  end

  test "session max status counts active agents separately from paused agents" do
    orchestrator_name = Module.concat(__MODULE__, :SessionMaxStatusOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 2,
          running: %{
            "issue-active" => running_entry("issue-active", "MT-ACTIVE", :working),
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused)
          }
      }
    end)

    assert %{
             active: 1,
             paused: 1,
             configured: 10,
             max: 2,
             session_override?: true,
             draining?: false
           } = Orchestrator.max_concurrent_agents(orchestrator_name)

    assert {:ok, %{max: 1, active: 1, paused: 1, session_override?: true, draining?: false}} =
             Orchestrator.adjust_max_concurrent_agents(orchestrator_name, -1)
  end

  test "session max can be decreased below current active agents to drain" do
    orchestrator_name = Module.concat(__MODULE__, :SessionMaxDrainOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 2,
          running: %{
            "issue-a" => running_entry("issue-a", "MT-A", :working),
            "issue-b" => running_entry("issue-b", "MT-B", :working)
          }
      }
    end)

    assert {:ok, %{max: 1, active: 2, draining?: true}} =
             Orchestrator.adjust_max_concurrent_agents(orchestrator_name, -1)

    assert %{max: 1, active: 2, draining?: true} =
             Orchestrator.max_concurrent_agents(orchestrator_name)
  end

  test "status returns running paused and idle agents" do
    orchestrator_name = Module.concat(__MODULE__, :AgentStatusOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{
            "issue-active" => %Issue{id: "issue-active", identifier: "repo#44", state: "In Progress", title: "Active"},
            "issue-paused" => %Issue{id: "issue-paused", identifier: "repo#45", state: "In Progress", title: "Paused"},
            "issue-idle" => %Issue{id: "issue-idle", identifier: "repo#46", state: "Todo", title: "Idle"}
          },
          running: %{
            "issue-active" => running_entry("issue-active", "repo#44", :working, self(), nil, "Active"),
            "issue-paused" => running_entry("issue-paused", "repo#45", :paused, self(), nil, "Paused")
          }
      }
    end)

    assert [
             %{identifier: "repo#44", state: :running, title: "Active"},
             %{identifier: "repo#45", state: :paused, title: "Paused"},
             %{identifier: "repo#46", state: :idle, title: "Idle"}
           ] = Orchestrator.status(orchestrator_name, 1_000)
  end

  test "status keeps cached and deactivated rows for control commands" do
    orchestrator_name = Module.concat(__MODULE__, :AgentStatusClosedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    deactivated =
      "issue-deactivated"
      |> running_entry("repo#491", :deactivated, self(), nil, "Deactivated")

    closed_running =
      "issue-closed-running"
      |> running_entry("repo#492", :working, self(), nil, "Closed running")
      |> update_in([:issue], &%{&1 | state: "Closed"})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{
            "issue-active" => %Issue{id: "issue-active", identifier: "repo#44", state: "In Progress", title: "Active"},
            "issue-closed-stale-label" => %Issue{
              id: "issue-closed-stale-label",
              identifier: "repo#523",
              state: "Closed",
              title: "Closed stale active label",
              labels: ["agent:human-review"]
            },
            "issue-unlabeled" => %Issue{
              id: "issue-unlabeled",
              identifier: "repo#524",
              state: nil,
              title: "Closed with active label removed"
            }
          },
          running: %{
            "issue-active" => running_entry("issue-active", "repo#44", :working, self(), nil, "Active"),
            "issue-deactivated" => deactivated,
            "issue-closed-running" => closed_running
          }
      }
    end)

    assert [
             %{identifier: "repo#44", state: :running, title: "Active", work_state: :working},
             %{identifier: "repo#491", state: :running, title: "Deactivated", work_state: :deactivated},
             %{identifier: "repo#492", state: :running, title: "Closed running", tracker_state: "Closed"},
             %{identifier: "repo#523", state: :idle, title: "Closed stale active label", tracker_state: "Closed"},
             %{identifier: "repo#524", state: :idle, title: "Closed with active label removed", tracker_state: nil}
           ] = Orchestrator.status(orchestrator_name, 1_000)
  end

  test "pause then resume round trip updates status around worker control messages" do
    # Null the Linear token so the orchestrator's startup poll fails *instantly*
    # with {:error, :missing_linear_api_token} — no real api.linear.app call to
    # block the GenServer (which timed out the 1s `status` call under load), and no
    # successful fetch (which would reconcile the injected running agent away and
    # kill its worker pid, here `self()`). The poll erroring is the pre-fix
    # behavior; this just makes it fast and network-free.
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    orchestrator_name = Module.concat(__MODULE__, :PauseResumeRoundTripOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-round-trip" => running_entry("issue-round-trip", "repo#47", :working, parent)
          }
      }
    end)

    assert {:ok, request_id} = Orchestrator.pause_agent(orchestrator_name, "repo#47")
    assert_receive {:pause_agent, ^request_id}, 500

    # Optimistic flip: the row reads :paused immediately from the operator
    # action, before the worker's async :worker_control_state confirmation —
    # so pressing space pauses the agent at any moment, even mid-spin-up.
    #
    # Each transition is read through `wait_for_status`, which retries the
    # `status` GenServer.call through transient :timeout. The pause/resume state
    # is set synchronously inside its handle_call before reply, so the value is
    # authoritative the instant the call returns — the only failure mode was the
    # 1s call timing out under CPU contention, which retrying absorbs. Mailbox
    # FIFO also guarantees the status read after the async :worker_control_state
    # send is processed *after* that message, so the read is properly ordered.
    assert [%{identifier: "repo#47", state: :paused}] =
             wait_for_status(orchestrator_name, &match?([%{identifier: "repo#47", state: :paused}], &1))

    send(pid, {:worker_control_state, "issue-round-trip", :paused})

    assert [%{identifier: "repo#47", state: :paused}] =
             wait_for_status(orchestrator_name, &match?([%{identifier: "repo#47", state: :paused}], &1))

    assert {:ok, :resumed} = Orchestrator.resume_agent(orchestrator_name, "repo#47")
    assert_receive {:resume_agent, resume_request_id} when is_integer(resume_request_id), 500

    assert [%{identifier: "repo#47", state: :running}] =
             wait_for_status(orchestrator_name, &match?([%{identifier: "repo#47", state: :running}], &1))
  end

  test "resuming a paused agent is blocked when active capacity is full" do
    orchestrator_name = Module.concat(__MODULE__, :ResumeCapacityBlockedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{
            "issue-active" => running_entry("issue-active", "MT-ACTIVE", :working),
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused)
          }
      }
    end)

    assert {:error, :max_concurrent_agents_reached} =
             Orchestrator.resume_agent(orchestrator_name, "MT-PAUSED")

    refute_receive {:resume_agent, _request_id}, 100
  end

  test "resuming a paused agent sends resume control and consumes active capacity" do
    orchestrator_name = Module.concat(__MODULE__, :ResumePausedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 2,
          running: %{
            "issue-active" => running_entry("issue-active", "MT-ACTIVE", :working, parent),
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused, parent)
          }
      }
    end)

    assert {:ok, :resumed} = Orchestrator.resume_agent(orchestrator_name, "MT-PAUSED")
    assert_receive {:resume_agent, request_id} when is_integer(request_id), 500
    assert %{active: 2, paused: 0, max: 2} = Orchestrator.max_concurrent_agents(orchestrator_name)
  end

  test "pause freezes started_at clock — paused_at is captured, started_at unchanged" do
    orchestrator_name = Module.concat(__MODULE__, :PauseClockFreezeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    started_at = DateTime.add(DateTime.utc_now(), -60, :second)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-clock" => %{
              pid: self(),
              ref: make_ref(),
              identifier: "MT-CLOCK",
              issue: %Issue{id: "issue-clock", identifier: "MT-CLOCK", state: "In Progress"},
              control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
              session_id: "thread-MT-CLOCK",
              started_at: started_at
            }
          }
      }
    end)

    send(pid, {:worker_control_state, "issue-clock", :paused})
    Process.sleep(20)

    paused_entry = :sys.get_state(pid).running["issue-clock"]
    assert %DateTime{} = paused_entry[:paused_at]
    assert paused_entry[:started_at] == started_at
  end

  test "resume shifts started_at forward by the paused interval so the age column excludes the pause" do
    orchestrator_name = Module.concat(__MODULE__, :PauseClockShiftOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    started_at = DateTime.add(DateTime.utc_now(), -60, :second)
    paused_at = DateTime.add(DateTime.utc_now(), -5, :second)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-shift" => %{
              pid: self(),
              ref: make_ref(),
              identifier: "MT-SHIFT",
              issue: %Issue{id: "issue-shift", identifier: "MT-SHIFT", state: "In Progress"},
              control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :paused},
              session_id: "thread-MT-SHIFT",
              started_at: started_at,
              paused_at: paused_at
            }
          }
      }
    end)

    send(pid, {:worker_control_state, "issue-shift", :working})
    Process.sleep(20)

    resumed_entry = :sys.get_state(pid).running["issue-shift"]
    refute Map.get(resumed_entry, :paused_at)
    # started_at should be shifted forward by ~5s (the pause duration).
    shift_seconds = DateTime.diff(resumed_entry.started_at, started_at, :second)

    assert shift_seconds in 4..6,
           "expected started_at shifted by ~5s, got #{shift_seconds}s"
  end

  test "resuming a paused agent into its reserved slot succeeds when no other active agents" do
    orchestrator_name = Module.concat(__MODULE__, :ResumePausedOnlySlotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    # max=1, no active, 1 paused: the paused agent already owns the slot,
    # so resume should succeed even though `available_slots` is 0.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused, parent)
          }
      }
    end)

    assert {:ok, :resumed} = Orchestrator.resume_agent(orchestrator_name, "MT-PAUSED")
    assert_receive {:resume_agent, request_id} when is_integer(request_id), 500
    assert %{active: 1, paused: 0, max: 1} = Orchestrator.max_concurrent_agents(orchestrator_name)
  end

  test "resuming a paused ssh agent is blocked when its worker host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    orchestrator_name = Module.concat(__MODULE__, :ResumePausedWorkerHostBlockedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 3,
          running: %{
            "issue-active-a" => running_entry("issue-active-a", "MT-ACTIVE-A", :working, parent, "worker-a"),
            "issue-active-b" => running_entry("issue-active-b", "MT-ACTIVE-B", :working, parent, "worker-b"),
            "issue-paused-a" => running_entry("issue-paused-a", "MT-PAUSED-A", :paused, parent, "worker-a")
          }
      }
    end)

    assert {:error, :max_concurrent_agents_reached} =
             Orchestrator.resume_agent(orchestrator_name, "MT-PAUSED-A")

    refute_receive {:resume_agent, _request_id}, 100
    assert %{active: 2, paused: 1, max: 3} = Orchestrator.max_concurrent_agents(orchestrator_name)
  end

  test "orchestrator snapshot reflects last codex update and session id" do
    issue_id = "issue-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-188",
      title: "Snapshot test",
      description: "Capture codex state",
      state: "In Progress",
      url: "https://example.org/issues/MT-188",
      labels: ["agent:todo", "backend"]
    }

    orchestrator_name = Module.concat(__MODULE__, :SnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }

    state_with_issue =
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))

    :sys.replace_state(pid, fn _ -> state_with_issue end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       normalize(%{
         event: :session_started,
         session_id: "thread-live-turn-live",
         timestamp: now
       })}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       normalize(%{
         event: :notification,
         payload: %{method: "some-event"},
         timestamp: now
       })}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.issue_id == issue_id
    assert snapshot_entry.session_id == "thread-live-turn-live"
    assert snapshot_entry.tag == "agent:todo"
    assert snapshot_entry.turn_count == 1
    assert snapshot_entry.last_codex_timestamp == now

    assert snapshot_entry.last_codex_message == %{
             event: :notification,
             message: %{method: "some-event"},
             timestamp: now
           }
  end

  test "orchestrator snapshot tracks codex thread totals and app-server pid" do
    issue_id = "issue-usage-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-201",
      title: "Usage snapshot test",
      description: "Collect usage stats",
      state: "In Progress",
      url: "https://example.org/issues/MT-201"
    }

    orchestrator_name = Module.concat(__MODULE__, :UsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       normalize(%{
         event: :session_started,
         session_id: "thread-usage-turn-usage",
         timestamp: now
       })}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       normalize(%{
         event: :notification,
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "tokenUsage" => %{
               "total" => %{"inputTokens" => 12, "outputTokens" => 4, "totalTokens" => 16}
             }
           }
         },
         timestamp: now,
         codex_app_server_pid: "4242"
       })}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_app_server_pid == "4242"
    assert snapshot_entry.agent_input_tokens == 12
    assert snapshot_entry.agent_output_tokens == 4
    assert snapshot_entry.agent_total_tokens == 16
    assert snapshot_entry.turn_count == 1
    assert is_integer(snapshot_entry.runtime_seconds)

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.agent_totals.input_tokens == 12
    assert completed_state.agent_totals.output_tokens == 4
    assert completed_state.agent_totals.total_tokens == 16
    assert is_integer(completed_state.agent_totals.seconds_running)
  end

  test "orchestrator snapshot tracks turn completed usage when present" do
    issue_id = "issue-turn-completed-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-202",
      title: "Turn completed usage test",
      description: "Track final turn usage",
      state: "In Progress",
      url: "https://example.org/issues/MT-202"
    }

    orchestrator_name = Module.concat(__MODULE__, :TurnCompletedUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       normalize(%{
         event: :turn_completed,
         payload: %{
           method: "turn/completed",
           usage: %{"input_tokens" => "12", "output_tokens" => 4, "total_tokens" => 16}
         },
         timestamp: DateTime.utc_now()
       })}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.agent_input_tokens == 12
    assert snapshot_entry.agent_output_tokens == 4
    assert snapshot_entry.agent_total_tokens == 16

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)
    assert completed_state.agent_totals.input_tokens == 12
    assert completed_state.agent_totals.output_tokens == 4
    assert completed_state.agent_totals.total_tokens == 16
  end

  test "orchestrator snapshot tracks codex token-count cumulative usage payloads" do
    issue_id = "issue-token-count-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-220",
      title: "Token count snapshot test",
      description: "Validate token-count style payloads",
      state: "In Progress",
      url: "https://example.org/issues/MT-220"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenCountOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       normalize(%{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "input_tokens" => "2",
                   "output_tokens" => 2,
                   "total_tokens" => 4
                 }
               }
             }
           }
         },
         timestamp: now
       })}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       normalize(%{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "prompt_tokens" => 10,
                   "completion_tokens" => 5,
                   "total_tokens" => 15
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       })}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.agent_input_tokens == 10
    assert snapshot_entry.agent_output_tokens == 5
    assert snapshot_entry.agent_total_tokens == 15

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.agent_totals.input_tokens == 10
    assert completed_state.agent_totals.output_tokens == 5
    assert completed_state.agent_totals.total_tokens == 15
  end

  test "orchestrator snapshot tracks codex rate-limit payloads" do
    issue_id = "issue-rate-limit-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-221",
      title: "Rate limit snapshot test",
      description: "Capture codex rate limit state",
      state: "In Progress",
      url: "https://example.org/issues/MT-221"
    }

    orchestrator_name = Module.concat(__MODULE__, :RateLimitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    rate_limits = %{
      "limit_id" => "codex",
      "primary" => %{"remaining" => 90, "limit" => 100},
      "secondary" => nil,
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => nil}
    }

    send(
      pid,
      {:codex_worker_update, issue_id,
       normalize(%{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "rate_limits" => rate_limits
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       })}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.rate_limits == rate_limits
  end

  test "orchestrator token accounting prefers total_token_usage over last_token_usage in token_count payloads" do
    issue_id = "issue-token-precedence"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-222",
      title: "Token precedence",
      description: "Prefer per-event deltas",
      state: "In Progress",
      url: "https://example.org/issues/MT-222"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenPrecedenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       normalize(%{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 2,
                     "output_tokens" => 1,
                     "total_tokens" => 3
                   },
                   "total_token_usage" => %{
                     "input_tokens" => 200,
                     "output_tokens" => 100,
                     "total_tokens" => 300
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       })}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.agent_input_tokens == 200
    assert snapshot_entry.agent_output_tokens == 100
    assert snapshot_entry.agent_total_tokens == 300
  end

  test "orchestrator token accounting accumulates monotonic thread token usage totals" do
    issue_id = "issue-thread-token-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-223",
      title: "Thread token usage",
      description: "Accumulate absolute thread totals",
      state: "In Progress",
      url: "https://example.org/issues/MT-223"
    }

    orchestrator_name = Module.concat(__MODULE__, :ThreadTokenUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    for usage <- [
          %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11},
          %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
        ] do
      send(
        pid,
        {:codex_worker_update, issue_id,
         normalize(%{
           event: :notification,
           payload: %{
             "method" => "thread/tokenUsage/updated",
             "params" => %{"tokenUsage" => %{"total" => usage}}
           },
           timestamp: DateTime.utc_now()
         })}
      )
    end

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.agent_input_tokens == 10
    assert snapshot_entry.agent_output_tokens == 4
    assert snapshot_entry.agent_total_tokens == 14
  end

  test "orchestrator token accounting ignores last_token_usage without cumulative totals" do
    issue_id = "issue-last-token-ignored"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-224",
      title: "Last token ignored",
      description: "Ignore delta-only token reports",
      state: "In Progress",
      url: "https://example.org/issues/MT-224"
    }

    orchestrator_name = Module.concat(__MODULE__, :LastTokenIgnoredOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       normalize(%{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 8,
                     "output_tokens" => 3,
                     "total_tokens" => 11
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       })}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.agent_input_tokens == 0
    assert snapshot_entry.agent_output_tokens == 0
    assert snapshot_entry.agent_total_tokens == 0
  end

  test "orchestrator snapshot includes retry backoff entries" do
    orchestrator_name = Module.concat(__MODULE__, :RetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    retry_entry = %{
      attempt: 2,
      timer_ref: nil,
      due_at_ms: System.monotonic_time(:millisecond) + 5_000,
      identifier: "MT-500",
      error: "agent exited: :boom"
    }

    initial_state = :sys.get_state(pid)
    new_state = %{initial_state | retry_attempts: %{"mt-500" => retry_entry}}
    :sys.replace_state(pid, fn _ -> new_state end)

    snapshot = GenServer.call(pid, :snapshot)
    assert is_list(snapshot.retrying)

    assert [
             %{
               issue_id: "mt-500",
               attempt: 2,
               due_in_ms: due_in_ms,
               identifier: "MT-500",
               error: "agent exited: :boom"
             }
           ] = snapshot.retrying

    assert due_in_ms > 0
  end

  test "orchestrator snapshot includes poll countdown and checking status" do
    orchestrator_name = Module.concat(__MODULE__, :PollingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    now_ms = System.monotonic_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 30_000,
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: now_ms + 4_000,
          poll_check_in_progress: false
      }
    end)

    snapshot = GenServer.call(pid, :snapshot)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 30_000,
               next_poll_in_ms: due_in_ms
             }
           } = snapshot

    assert is_integer(due_in_ms)
    assert due_in_ms >= 0
    assert due_in_ms <= 4_000

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{polling: %{checking?: true, next_poll_in_ms: nil}} = snapshot
  end

  test "orchestrator triggers an immediate poll cycle shortly after startup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_seconds: 5
    )

    orchestrator_name = Module.concat(__MODULE__, :ImmediateStartupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert %{polling: %{checking?: true}} =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: true}} ->
                   true

                 _ ->
                   false
               end,
               500
             )

    assert %{
             polling: %{
               checking?: false,
               next_poll_in_ms: next_poll_in_ms,
               poll_interval_ms: 5_000
             }
           } =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}}
                 when is_integer(due_in_ms) and due_in_ms <= 5_000 ->
                   true

                 _ ->
                   false
               end,
               500
             )

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
  end

  test "orchestrator poll cycle resets next refresh countdown after a check" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_seconds: 1
    )

    orchestrator_name = Module.concat(__MODULE__, :PollCycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 1_000,
          poll_check_in_progress: true,
          next_poll_due_at_ms: nil
      }
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(pid, fn
        %{polling: %{checking?: false, poll_interval_ms: 1_000, next_poll_in_ms: next_poll_in_ms}}
        when is_integer(next_poll_in_ms) and next_poll_in_ms <= 1_000 ->
          true

        _ ->
          false
      end)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 1_000,
               next_poll_in_ms: next_poll_in_ms
             }
           } = snapshot

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
    assert next_poll_in_ms <= 1_000
  end

  test "orchestrator enqueues operator messages and pause requests for the running agent task" do
    orchestrator_name = Module.concat(__MODULE__, :OperatorMessageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    parent = self()

    worker_pid =
      spawn(fn ->
        operator_message_probe(parent)
      end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-chat" => %{
              pid: worker_pid,
              ref: make_ref(),
              identifier: "MT-CHAT",
              issue: %Issue{id: "issue-chat", identifier: "MT-CHAT", state: "In Progress"},
              control: %{
                can_interrupt: true,
                safe_checkpoints: [:notification, :tool_result],
                status: :working
              },
              session_id: "thread-chat-turn-chat",
              agent_input_tokens: 0,
              agent_output_tokens: 0,
              agent_total_tokens: 0,
              started_at: DateTime.utc_now()
            }
          }
      }
    end)

    assert {:ok, request_id} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-CHAT", %{kind: :text, body: "hello"})

    assert is_integer(request_id)
    assert_receive {:agent_queue_updated, "MT-CHAT", ^request_id, false}

    assert {:ok, %{id: ^request_id, category: :operator_message, body: %{text: "hello"}}} =
             Orchestrator.claim_next_queue_item_for_test(orchestrator_name, "MT-CHAT")

    assert {:ok,
            %{
              accepts_operator_messages: true,
              can_interrupt: true,
              accepted_delivery_policies: [:checkpoint, :interrupt],
              queue_depth: 0
            }} = Orchestrator.control_capabilities(orchestrator_name, "MT-CHAT")

    assert {:ok, pause_request_id} = Orchestrator.pause_agent(orchestrator_name, "MT-CHAT")
    assert_receive {:pause_agent, ^pause_request_id}

    assert {:ok, interrupt_request_id} =
             Orchestrator.send_operator_message(
               orchestrator_name,
               "MT-CHAT",
               %{kind: :text, body: "stop now", delivery_policy: :interrupt}
             )

    assert is_integer(interrupt_request_id)

    assert :empty = Orchestrator.claim_next_checkpoint_queue_item(orchestrator_name, "MT-CHAT")

    assert {:ok,
            %{
              id: ^interrupt_request_id,
              category: :operator_message,
              delivery: %{interrupt_requested: true, priority: :now}
            }} =
             Orchestrator.claim_next_queue_item_for_test(orchestrator_name, "MT-CHAT")

    assert {:error, :empty_message} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-CHAT", %{kind: :text, body: "   "})

    assert {:error, :no_running_agent} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-MISSING", %{kind: :text, body: "hello"})
  end

  test "chat-send to a paused agent auto-resumes it when a slot is free" do
    orchestrator_name = Module.concat(__MODULE__, :ChatPausedAutoResumeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    # max=2, no active agents, 1 paused — there's a free slot, so chatting
    # with the paused agent auto-resumes and enqueues the message instead
    # of erroring. Mirrors the behavior of pressing space on the paused
    # row from the agent list.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 2,
          running: %{
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused, parent)
          }
      }
    end)

    assert {:ok, request_id} =
             Orchestrator.send_operator_message(
               orchestrator_name,
               "MT-PAUSED",
               %{kind: :text, body: "hi"}
             )

    assert is_integer(request_id)
    assert_receive {:resume_agent, _resume_request_id}, 500

    status = Orchestrator.max_concurrent_agents(orchestrator_name)
    assert status.active == 1
    assert status.paused == 0
  end

  test "chat-send to a paused agent errors when no slot is free" do
    orchestrator_name = Module.concat(__MODULE__, :ChatPausedNoCapacityOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    # max=1, 1 active, 1 paused — no free slot. Chat-send to the paused
    # agent must refuse rather than silently flip it to :working and push
    # active over max. The operator must explicitly free capacity first.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{
            "issue-active" => running_entry("issue-active", "MT-ACTIVE", :working, parent),
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused, parent)
          }
      }
    end)

    assert {:error, :max_concurrent_agents_reached} =
             Orchestrator.send_operator_message(
               orchestrator_name,
               "MT-PAUSED",
               %{kind: :text, body: "hi"}
             )

    refute_receive {:resume_agent, _request_id}, 100

    status = Orchestrator.max_concurrent_agents(orchestrator_name)
    assert status.active == 1
    assert status.paused == 1
  end

  test "orchestrator can claim only operator queue items without consuming coordination events" do
    orchestrator_name = Module.concat(__MODULE__, :OperatorOnlyClaimOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      {queue_store, _event_item} =
        Aiur.AgentQueue.coordination_event("MT-QUEUE", :blocker_update, %{summary: "still blocked"})
        |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

      {queue_store, _operator_item} =
        Aiur.AgentQueue.operator_message("MT-QUEUE", "resume now")
        |> then(&Aiur.AgentQueueStore.enqueue(queue_store, &1))

      %{state | queue_store: queue_store}
    end)

    assert {:ok, %{category: :operator_message, body: %{text: "resume now"}}} =
             Orchestrator.claim_next_operator_queue_item(orchestrator_name, "MT-QUEUE")

    assert {:ok, %{category: :coordination_event, body: %{summary: "still blocked"}}} =
             Orchestrator.claim_next_queue_item_for_test(orchestrator_name, "MT-QUEUE")
  end

  test "orchestrator restarts stalled workers with retry backoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      agent_stall_timeout_ms: 1_000
    )

    issue_id = "issue-stall"
    orchestrator_name = Module.concat(__MODULE__, :StallOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-STALL",
      issue: %Issue{id: issue_id, identifier: "MT-STALL", state: "In Progress"},
      session_id: "thread-stall-turn-stall",
      last_codex_message: nil,
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :notification,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    tick_at_ms = System.monotonic_time(:millisecond)
    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid)
    observed_at_ms = System.monotonic_time(:millisecond)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-STALL",
             error: "stalled for " <> _
           } = state.retry_attempts[issue_id]

    assert is_integer(due_at_ms)

    # Attempt 1 schedules a fixed 10s base backoff (@failure_retry_base_ms).
    # `due_at_ms` was set to (monotonic_at_schedule + 10_000) at some instant
    # between the tick send and our state read, so it is bounded by those two
    # monotonic readings. Asserting that window is load-independent: a slow
    # scheduler shifts both endpoints together and cannot push `due_at_ms`
    # outside it, unlike the previous `remaining >= 9_500` slack budget that a
    # ~600ms scheduling stall was enough to blow.
    assert due_at_ms >= tick_at_ms + 10_000
    assert due_at_ms <= observed_at_ms + 10_000
  end

  test "orchestrator emits blocker coordination events from poll transitions" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Cancelled"]
    )

    blocker = fn state ->
      %Issue{id: "blocker-1", identifier: "MT-1", title: "Blocker", state: state, blocked_by: []}
    end

    blocked_issue = fn blocker_state ->
      %Issue{
        id: "blocked-1",
        identifier: "MT-2",
        title: "Blocked issue",
        state: "Todo",
        blocked_by: [%{id: "blocker-1", identifier: "MT-1", state: blocker_state}]
      }
    end

    Application.put_env(:aiur, :memory_tracker_issues, [
      blocker.("In Progress"),
      blocked_issue.("In Progress")
    ])

    orchestrator_name = Module.concat(__MODULE__, :DependencyEventOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:aiur, :memory_tracker_issues)

      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    send(pid, :run_poll_cycle)
    Process.sleep(25)

    assert :empty == Orchestrator.claim_next_queue_item(orchestrator_name, "MT-2")

    Application.put_env(:aiur, :memory_tracker_issues, [
      blocker.("Done"),
      blocked_issue.("Done")
    ])

    send(pid, :run_poll_cycle)
    Process.sleep(25)

    assert {:ok,
            %{
              category: :coordination_event,
              event_type: :blocker_became_terminal,
              body: %{blocker_issue_identifier: "MT-1", blocked_issue_identifier: "MT-2"}
            }} = Orchestrator.claim_next_queue_item(orchestrator_name, "MT-2")
  end

  test "application configures a single-file logger handler when AIUR_DEBUG=1" do
    # The file handler is now gated on AIUR_DEBUG so the default
    # quiet `aiur` invocation doesn't write aiur.log. Set the env
    # and re-configure to verify the handler still installs cleanly
    # in debug mode.
    original = System.get_env("AIUR_DEBUG")
    System.put_env("AIUR_DEBUG", "1")
    Aiur.LogFile.configure()

    on_exit(fn ->
      case original do
        nil -> System.delete_env("AIUR_DEBUG")
        v -> System.put_env("AIUR_DEBUG", v)
      end

      Aiur.LogFile.configure()
    end)

    assert {:ok, handler_config} = :logger.get_handler_config(:aiur_file_log)
    assert handler_config.module == :logger_std_h

    file_config = handler_config.config
    assert file_config.type == :file
    assert is_list(file_config.file)
  end

  defp wait_for_status(orchestrator_name, predicate, timeout_ms \\ 5_000)
       when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_status(orchestrator_name, predicate, deadline_ms)
  end

  defp do_wait_for_status(orchestrator_name, predicate, deadline_ms) do
    status = Orchestrator.status(orchestrator_name, 1_000)

    if is_list(status) and predicate.(status) do
      status
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator status: #{inspect(status)}")
      else
        Process.sleep(5)
        do_wait_for_status(orchestrator_name, predicate, deadline_ms)
      end
    end
  end

  defp wait_for_snapshot(pid, predicate, timeout_ms \\ 200) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_snapshot(pid, predicate, deadline_ms)
  end

  defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if predicate.(snapshot) do
      snapshot
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator snapshot state: #{inspect(snapshot)}")
      else
        Process.sleep(5)
        do_wait_for_snapshot(pid, predicate, deadline_ms)
      end
    end
  end

  defp operator_message_probe(parent) do
    receive do
      message ->
        send(parent, message)
        operator_message_probe(parent)
    end
  end
end
