defmodule Aiur.OrchestratorStatusTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{AgentControlCLI, AgentPubSub, AgentQueueStore, Issue, TrackerIdentity}
  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.Codex.CodingAgent, as: CodexCodingAgent
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Opencode.ActiveTurns

  alias Aiur.Orchestrator.{
    CiLifecycle,
    HumanReview,
    OperatorMessages,
    PauseResume,
    Reconciler,
    SnapshotPublisher,
    SnapshotStore,
    State,
    StatusReport,
    WorkspaceCleanup
  }

  alias Aiur.SessionHandle

  defmodule StartupCleanupLinearClient do
    def fetch_candidate_issues, do: {:ok, []}

    def fetch_issues_by_states(states), do: fetch_issues_by_states(states, [])

    def fetch_issues_by_states(_states, opts) do
      notify({:startup_cleanup_fetch_issues_by_states, opts})
      {:error, {:linear_api_status, 401}}
    end

    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

    def graphql(query, %{"issueId" => _issue_id, "stateName" => "rework"})
        when is_binary(query) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"states" => %{"nodes" => [%{"id" => "state-rework"}]}}
           }
         }
       }}
    end

    def graphql(query, %{issueId: _issue_id, stateName: "rework"})
        when is_binary(query) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"states" => %{"nodes" => [%{"id" => "state-rework"}]}}
           }
         }
       }}
    end

    def graphql(query, %{"issueId" => _issue_id, "stateId" => "state-rework"})
        when is_binary(query) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    end

    def graphql(query, %{issueId: _issue_id, stateId: "state-rework"})
        when is_binary(query) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    end

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
      {:ok, Application.get_env(:aiur, :startup_cleanup_issues, [])}
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
      issue: %Issue{
        id: issue_id,
        identifier: identifier,
        state: "In Progress",
        title: title,
        tracker_identity: tracker_identity(identifier)
      },
      worker_host: worker_host,
      control: %{
        can_interrupt: true,
        safe_checkpoints: [:notification],
        status: status,
        application_confirmation: :confirmed,
        generation: 1,
        version: 0
      },
      codex_app_server_pid: nil,
      codex_process_group_id: nil,
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }
  end

  defp tracker_identity(identifier) do
    identity_identifier =
      case Regex.run(~r/\d+$/, identifier) do
        [number] -> number
        nil -> "1"
      end

    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I_kwDO#{identifier}",
      identifier: identity_identifier,
      reason: nil
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

  test "dashboard snapshot reads the cached fleet while the orchestrator mailbox is saturated" do
    orchestrator_name = Module.concat(__MODULE__, :CachedSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      try do
        :sys.resume(pid)
      catch
        :exit, _reason -> :ok
      end

      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :ok =
      SnapshotStore.publish(
        orchestrator_name,
        pid |> :sys.get_state() |> StatusReport.snapshot_payload()
      )

    :sys.suspend(pid)
    send(pid, :dispatch_backlog)
    Process.sleep(110)

    log =
      capture_log([level: :warning], fn ->
        task = Task.async(fn -> Orchestrator.dashboard_snapshot(orchestrator_name, 100) end)

        assert {:ok, {:stale, %{running: [], retrying: [], idle: []}, %{status: :stale}}} =
                 Task.yield(task, 25)
      end)

    assert log =~ "Dashboard snapshot timed out"
    assert log =~ "orchestrator_mailbox_depth="
  end

  test "keeps a busy-but-publishing orchestrator's fleet snapshot current within its load-aware window" do
    orchestrator_name = Module.concat(__MODULE__, :LoadAwareWindowSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      try do
        :sys.resume(pid)
      catch
        :exit, _reason -> :ok
      end

      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    snapshot = %{running: [], retrying: [], idle: []}

    # A dispatching orchestrator only manages to refresh on a load-imposed
    # cadence well past the configured 50ms staleness timeout: the second
    # snapshot lands after a 200ms gap.
    :ok = SnapshotStore.publish(orchestrator_name, snapshot)
    Process.sleep(200)
    :ok = SnapshotStore.publish(orchestrator_name, snapshot)

    # Let the snapshot age past the fixed timeout while staying inside the
    # load-aware window, then saturate the orchestrator mailbox to simulate a
    # backlogged (but live) dispatcher.
    Process.sleep(80)
    :sys.suspend(pid)
    send(pid, :dispatch_backlog)

    assert {:current, %{running: [], retrying: [], idle: []}, %{status: :current, freshness_window_ms: window}} =
             Orchestrator.dashboard_snapshot(orchestrator_name, 50)

    assert window >= 200 * 2

    # A snapshot published at a fast cadence and then going quiet is still
    # flagged stale: the load-aware window must not mask a genuine stall.
    stalled_name = Module.concat(__MODULE__, :StalledFastCadenceSnapshotOrchestrator)
    {:ok, stalled_pid} = Orchestrator.start_link(name: stalled_name, initial_poll?: false)

    on_exit(fn ->
      try do
        :sys.resume(stalled_pid)
      catch
        :exit, _reason -> :ok
      end

      if Process.alive?(stalled_pid), do: Process.exit(stalled_pid, :normal)
    end)

    :ok = SnapshotStore.publish(stalled_name, snapshot)
    Process.sleep(30)
    :ok = SnapshotStore.publish(stalled_name, snapshot)
    Process.sleep(150)
    :sys.suspend(stalled_pid)
    send(stalled_pid, :dispatch_backlog)

    assert {:stale, %{running: [], retrying: [], idle: []}, %{status: :stale, reason: :snapshot_timeout}} =
             Orchestrator.dashboard_snapshot(stalled_name, 50)
  end

  test "decoupled publisher keeps the fleet snapshot current while the orchestrator is starved" do
    orchestrator_name = Module.concat(__MODULE__, :PublisherDecoupledSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      try do
        :sys.resume(pid)
      catch
        :exit, _reason -> :ok
      end

      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, &%{&1 | snapshot_ready?: true})
    state = :sys.get_state(pid)
    generation = state.snapshot_generation

    # The orchestrator's normal publish path records its latest input in the
    # shared write-model; the periodic SnapshotPublisher (not the orchestrator)
    # projects it, so the dashboard cadence is not gated on this mailbox.
    :ok = StatusReport.notify_dashboard(state)

    # Guard the decoupling wiring itself: publish_snapshot must record to the
    # publisher's write-model (a fast, non-blocking ETS insert) rather than
    # casting directly to SnapshotStore. If it reverted to the old direct cast,
    # the write-model row below would be absent and the projection-under-freeze
    # assertions would silently pass anyway — exactly the root-cause regression
    # this ticket exists to prevent.
    assert [{^orchestrator_name, ^generation, _version, %State{}}] =
             :ets.lookup(SnapshotPublisher, orchestrator_name)

    assert {:current, %{agent_totals: %{input_tokens: 0}}, %{status: :current}} =
             wait_for_published_snapshot(
               orchestrator_name,
               &match?(%{agent_totals: %{input_tokens: 0}}, &1)
             )

    # Freeze the orchestrator (a dispatch mailbox so backlogged it never
    # reaches a publish-triggering tick) and leave a message in its mailbox so
    # staleness detection observes a non-empty dispatch queue.
    :sys.suspend(pid)
    send(pid, :dispatch_backlog)

    # The dispatcher's state advances while starved; the decoupled write path
    # records it and the publisher projects it on its own cadence.
    :ok =
      SnapshotPublisher.write(
        orchestrator_name,
        generation,
        %State{agent_totals: %{input_tokens: 7, output_tokens: 0, total_tokens: 7, seconds_running: 0}}
      )

    assert {:current, %{agent_totals: %{input_tokens: 7}}, %{status: :current}} =
             wait_for_published_snapshot(
               orchestrator_name,
               &match?(%{agent_totals: %{input_tokens: 7}}, &1)
             )
  end

  test "decoupled publisher does not republish an unchanged write-model (stall not masked)" do
    orchestrator_name = Module.concat(__MODULE__, :PublisherNoHeartbeatSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      try do
        :sys.resume(pid)
      catch
        :exit, _reason -> :ok
      end

      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, &%{&1 | snapshot_ready?: true})
    :ok = StatusReport.notify_dashboard(:sys.get_state(pid))

    assert {:current, _, %{status: :current}} =
             wait_for_published_snapshot(orchestrator_name, fn _snapshot -> true end)

    # Freeze the orchestrator and stop writing: the publisher must NOT
    # republish the unchanged input as a heartbeat, so the snapshot's
    # observed-at ages and the read flags the stall instead of masking it.
    :sys.suspend(pid)
    send(pid, :dispatch_backlog)

    assert eventually?(
             fn ->
               match?(
                 {:stale, _, %{status: :stale, reason: :snapshot_timeout}},
                 Orchestrator.dashboard_snapshot(orchestrator_name, 100)
               )
             end,
             200
           )
  end

  test "a new snapshot generation resets the recent gap history" do
    orchestrator_name = Module.concat(__MODULE__, :GenerationGapResetSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    snapshot = %{running: [], retrying: [], idle: []}

    # A slow-cadence first generation widens its load-aware freshness window.
    SnapshotStore.begin_generation(orchestrator_name)
    :ok = SnapshotStore.publish(orchestrator_name, snapshot)
    Process.sleep(80)
    :ok = SnapshotStore.publish(orchestrator_name, snapshot)

    assert {:current, _, %{freshness_window_ms: widened}} =
             Orchestrator.dashboard_snapshot(orchestrator_name, 100)

    assert widened > 100

    # A restarted orchestrator begins a new generation: it must not inherit the
    # prior instance's gap history, so the window collapses back to the timeout
    # (P2-1 from the #1546 review).
    SnapshotStore.begin_generation(orchestrator_name)
    :ok = SnapshotStore.publish(orchestrator_name, snapshot)

    assert {:current, _, %{freshness_window_ms: fresh}} =
             Orchestrator.dashboard_snapshot(orchestrator_name, 100)

    assert fresh == 100
  end

  test "a new snapshot generation clears the prior instance's write-model entry" do
    orchestrator_name = Module.concat(__MODULE__, :GenerationWriteModelClearOrchestrator)

    # The prior instance's bounded input sits in the shared write-model under
    # its old generation token.
    SnapshotStore.begin_generation(orchestrator_name)
    :ok = SnapshotPublisher.write(orchestrator_name, make_ref(), %State{agent_totals: %{}})

    assert [{^orchestrator_name, _generation, _version, %State{}}] =
             :ets.lookup(SnapshotPublisher, orchestrator_name)

    # A restarted orchestrator begins a new generation; the publisher must drop
    # the prior instance's fenced entry so it never casts stale input under the
    # new token (P2-1 generation pollution, publisher side).
    SnapshotStore.begin_generation(orchestrator_name)

    assert [] = :ets.lookup(SnapshotPublisher, orchestrator_name)
  end

  test "discarding an unnamed snapshot removes the publisher delivery marker" do
    orchestrator = self()
    generation = SnapshotStore.begin_generation(orchestrator)

    :ok = SnapshotPublisher.write(orchestrator, generation, %State{agent_totals: %{}})

    assert eventually?(fn ->
             Map.has_key?(:sys.get_state(SnapshotPublisher), orchestrator)
           end)

    assert :ok = SnapshotStore.discard(orchestrator)
    assert [] = :ets.lookup(SnapshotPublisher, orchestrator)
    refute Map.has_key?(:sys.get_state(SnapshotPublisher), orchestrator)
  end

  test "stopping an unnamed orchestrator discards its snapshot state" do
    {:ok, orchestrator} = Orchestrator.start_link(initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(orchestrator), do: Process.exit(orchestrator, :normal)
    end)

    :sys.replace_state(orchestrator, &%{&1 | snapshot_ready?: true})
    state = :sys.get_state(orchestrator)
    :ok = StatusReport.notify_dashboard(state)

    assert eventually?(fn ->
             Map.has_key?(:sys.get_state(SnapshotPublisher), orchestrator)
           end)

    assert :ok = GenServer.stop(orchestrator, :normal)
    assert [] = :ets.lookup(SnapshotPublisher, orchestrator)
    refute Map.has_key?(:sys.get_state(SnapshotPublisher), orchestrator)
    assert :snapshot_timeout = SnapshotStore.read(orchestrator, 50)
  end

  test "dashboard serves its last-known-good snapshot when the orchestrator is unavailable" do
    orchestrator_name = Module.concat(__MODULE__, :RestartingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    :ok =
      SnapshotStore.publish(
        orchestrator_name,
        pid |> :sys.get_state() |> StatusReport.snapshot_payload()
      )

    assert :ok = GenServer.stop(pid, :normal)

    {:ok, restarted_pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(restarted_pid), do: Process.exit(restarted_pid, :normal)
    end)

    assert {:stale, %{running: [], retrying: [], idle: []}, freshness} =
             Orchestrator.dashboard_snapshot(orchestrator_name, 100)

    assert freshness.status == :stale
    assert freshness.reason == :orchestrator_unavailable
  end

  test "dashboard projection excludes unrelated orchestration state" do
    {queue_store, _item} =
      AgentQueueStore.enqueue(
        AgentQueueStore.new(),
        Aiur.AgentQueue.operator_message("MT-UNRELATED", String.duplicate("q", 64_000))
      )

    state = %State{
      github_comment_issue_updated_at: Map.new(1..1_000, &{"issue-#{&1}", %{payload: String.duplicate("x", 64)}}),
      ci_lifecycle: %{
        %State{}.ci_lifecycle
        | poll_cache: Map.new(1..1_000, &{"MT-#{&1}", %{payload: String.duplicate("c", 64)}})
      },
      control_lifecycle: %Aiur.Orchestrator.ControlLifecycle{
        records: Map.new(1..1_000, &{"request-#{&1}", %{payload: String.duplicate("l", 64)}})
      },
      queue_store: queue_store
    }

    snapshot_input = StatusReport.snapshot_input(state)

    assert snapshot_input.github_comment_issue_updated_at == %{}
    assert snapshot_input.queue_store == AgentQueueStore.new()
    assert snapshot_input.ci_lifecycle == %State{}.ci_lifecycle
    assert snapshot_input.control_lifecycle == %Aiur.Orchestrator.ControlLifecycle{}
    assert :erts_debug.size(snapshot_input) < 1_000
    assert :erts_debug.size(snapshot_input) * 100 < :erts_debug.size(state)
  end

  test "dashboard projection retains queue facts for rendered issues" do
    {queue_store, _item} =
      AgentQueueStore.enqueue(
        AgentQueueStore.new(),
        Aiur.AgentQueue.operator_message("MT-QUEUED", "show this message")
      )

    state = %State{
      running: %{"issue-queued" => running_entry("issue-queued", "MT-QUEUED", :working)},
      queue_store: queue_store
    }

    snapshot = state |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()

    assert [%{queue_depth: 1, pending_operator_messages: [%{text: "show this message"}]}] = snapshot.running
  end

  test "dashboard projection retains CI facts for retries absent from the latest poll" do
    state = %State{
      retry_attempts: %{
        "issue-retrying" => %{
          attempt: 2,
          due_at_ms: System.monotonic_time(:millisecond) + 1_000,
          identifier: "MT-RETRY-CI"
        }
      },
      ci_lifecycle: %{
        %State{}.ci_lifecycle
        | poll_cache: %{"MT-RETRY-CI" => %{decision: :pending, pr_number: 1501}}
      }
    }

    snapshot = state |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()

    assert [%{identifier: "MT-RETRY-CI", ci_result: %{decision: :pending, pr_number: 1501}}] = snapshot.retrying
  end

  test "capacity hold is projected with the measured limiting signal and threshold" do
    held_at = System.monotonic_time(:millisecond) - 5_000

    state = %State{
      capacity_hold: %{
        signal: :build,
        measured: %{active: 2, queued: 1},
        threshold: 2,
        held_since_ms: held_at,
        alerted?: true
      }
    }

    snapshot = state |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()

    assert %{
             held?: true,
             signal: :build,
             measured: %{active: 2, queued: 1},
             threshold: 2,
             held_for_seconds: 5
           } = snapshot.capacity_hold
  end

  test "an absent capacity hold projects a not-held block" do
    snapshot = %State{} |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()

    assert %{held?: false, signal: nil, threshold: nil} = snapshot.capacity_hold
  end

  test "an old projector cannot replace a same-name orchestrator snapshot" do
    orchestrator_name = Module.concat(__MODULE__, :GenerationFencedSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    fresh_snapshot = %{running: [], retrying: [], idle: [], marker: :fresh}
    :ok = SnapshotStore.publish(orchestrator_name, fresh_snapshot)

    callback_ref = make_ref()

    assert {:noreply, _store} =
             SnapshotStore.handle_info(
               {:snapshot_built, callback_ref, orchestrator_name, make_ref(), {:ok, %{marker: :stale}}},
               %{pending: %{}, task_ref: callback_ref, monitor_ref: nil, timer_ref: nil}
             )

    assert {:current, snapshot, _freshness} = Orchestrator.dashboard_snapshot(orchestrator_name, 100)
    assert Map.take(snapshot, Map.keys(fresh_snapshot)) == fresh_snapshot
    assert snapshot.globally_paused == false
    assert snapshot.global_pause == %{globally_paused: false, paused_at: nil, source: nil}
  end

  test "an old generation cannot evict a newer pending projection" do
    orchestrator = self()
    current_generation = SnapshotStore.begin_generation(orchestrator)
    stale_generation = make_ref()
    snapshot_input = %State{agent_totals: %{total_tokens: 2}}
    store = %{pending: %{}, task_ref: nil, monitor_ref: nil, timer_ref: nil}

    assert {:noreply, store} =
             SnapshotStore.handle_cast(
               {:publish_state, orchestrator, current_generation, snapshot_input},
               store
             )

    assert {:noreply, stale_store} =
             SnapshotStore.handle_cast(
               {:publish_state, orchestrator, stale_generation, %State{agent_totals: %{total_tokens: 1}}},
               store
             )

    assert stale_store.pending == store.pending
    Process.cancel_timer(store.timer_ref)
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
                   WorkspaceCleanup.run_terminal_workspace_cleanup(%Orchestrator.State{})
        end)

      refute_received {:startup_cleanup_fetch_issues_by_states, _opts}
      assert log =~ "Skipping startup terminal workspace cleanup: :missing_linear_api_token"
      # A blanket `refute log =~ "[warning]"/"[error]"` would pollute on an
      # unrelated concurrent test's warning: `capture_log` captures the whole
      # BEAM's log stream, not just this process's (the #594 flake class). But
      # the positive assertion above matches regardless of level, so it alone
      # doesn't prove this path stays at debug — scope the refute to this
      # path's own message instead of the whole captured stream.
      refute log =~ ~r/\[(warning|error)\].*Skipping startup terminal workspace cleanup/
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
                   WorkspaceCleanup.run_terminal_workspace_cleanup(%Orchestrator.State{})
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
                   WorkspaceCleanup.run_terminal_workspace_cleanup(%Orchestrator.State{})
        end)

      assert_received {:startup_cleanup_fetch_issues_by_states, opts}
      assert Keyword.fetch!(opts, :quiet_auth_errors?) == true
      assert log =~ "Skipping startup terminal workspace cleanup; failed to fetch terminal issues: {:linear_api_status, 401}"
      # No global `refute log =~ "[warning]"/"[error]"` here: `capture_log`
      # captures the whole BEAM's log stream, so an unrelated concurrent test
      # emitting a warning/error pollutes this assertion (the #594 flake class).
      # The positive assertion above already proves the auth failure is demoted
      # to debug.
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
               WorkspaceCleanup.run_terminal_workspace_cleanup(%Orchestrator.State{})

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

  test "startup terminal cleanup clears persisted session handles" do
    previous_github_client = Application.get_env(:aiur, :github_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)
    previous_issues = Application.get_env(:aiur, :startup_cleanup_issues)
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_log_file = Application.get_env(:aiur, :log_file)
    workspace_root = Path.join(System.tmp_dir!(), "aiur-startup-terminal-cleanup-#{System.unique_integer([:positive])}")

    try do
      System.put_env("GITHUB_TOKEN", "gh-test-token")
      Application.put_env(:aiur, :log_file, Path.join([workspace_root, "log", "agent.md"]))

      terminal_workspace = Path.join([workspace_root, "owner", "repo", "610"])
      File.mkdir_p!(terminal_workspace)
      File.write!(Path.join(terminal_workspace, "dirty.txt"), "leftover")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress"],
        tracker_terminal_states: ["done"],
        workspace_root: workspace_root,
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :github_client_module, StartupCleanupGitHubClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      Application.put_env(:aiur, :startup_cleanup_issues, [
        %Issue{id: "issue-610", identifier: "610", title: "Done", state: "done"}
      ])

      :ok = SessionHandle.save("610", %{backend: "codex", thread_id: "thread-clear"})

      assert %Orchestrator.State{} =
               WorkspaceCleanup.run_terminal_workspace_cleanup(%Orchestrator.State{})

      assert_received {:github_startup_cleanup_fetch_issues_by_states, ["done"], opts}
      assert Keyword.fetch!(opts, :quiet_auth_errors?) == true
      refute File.exists?(terminal_workspace)
      assert :none == SessionHandle.load("610", "codex")
    after
      restore_application_env(:github_client_module, previous_github_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
      restore_application_env(:startup_cleanup_issues, previous_issues)
      restore_application_env(:log_file, previous_log_file)
      restore_env("GITHUB_TOKEN", previous_github_token)
      File.rm_rf(workspace_root)
    end
  end

  test "startup todo cleanup removes stale todo workspaces before dispatch" do
    previous_github_client = Application.get_env(:aiur, :github_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)
    previous_issues = Application.get_env(:aiur, :startup_cleanup_issues)
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_log_file = Application.get_env(:aiur, :log_file)
    workspace_root = Path.join(System.tmp_dir!(), "aiur-startup-todo-cleanup-#{System.unique_integer([:positive])}")

    try do
      System.put_env("GITHUB_TOKEN", "gh-test-token")
      Application.put_env(:aiur, :log_file, Path.join([workspace_root, "log", "agent.md"]))

      todo_workspace = Path.join([workspace_root, "owner", "repo", "586"])
      in_progress_workspace = Path.join([workspace_root, "owner", "repo", "587"])
      File.mkdir_p!(todo_workspace)
      File.mkdir_p!(in_progress_workspace)
      File.write!(Path.join(todo_workspace, "dirty.txt"), "leftover")
      File.write!(Path.join(in_progress_workspace, "dirty.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress"],
        tracker_terminal_states: ["done"],
        workspace_root: workspace_root,
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :github_client_module, StartupCleanupGitHubClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      Application.put_env(:aiur, :startup_cleanup_issues, [
        %Issue{id: "issue-586", identifier: "586", title: "Todo", state: "todo"},
        %Issue{id: "issue-587", identifier: "587", title: "Live", state: "in-progress"}
      ])

      # `todo` is NOT a terminal state, so this startup cleanup must remove the
      # stale workspace WITHOUT clearing the resume handle — a re-dispatched todo
      # issue should still be able to rejoin its prior thread now that
      # `claude-repl` is resumable (#613). The terminal-cleanup path is what
      # clears the handle (see the terminal-cleanup test above).
      :ok = SessionHandle.save("586", %{backend: "claude-repl", thread_id: "thread-keep"})

      assert %Orchestrator.State{} =
               WorkspaceCleanup.run_startup_todo_workspace_cleanup(%Orchestrator.State{})

      assert_received {:github_startup_cleanup_fetch_issues_by_states, ["todo"], opts}
      assert Keyword.fetch!(opts, :quiet_auth_errors?) == true
      refute File.exists?(todo_workspace)
      assert File.exists?(in_progress_workspace)
      assert File.read!(Path.join(in_progress_workspace, "dirty.txt")) == "keep"
      # Non-terminal cleanup leaves the resume handle intact.
      assert {:ok, %{thread_id: "thread-keep"}} = SessionHandle.load("586", "claude-repl")
    after
      restore_application_env(:github_client_module, previous_github_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
      restore_application_env(:startup_cleanup_issues, previous_issues)
      restore_application_env(:log_file, previous_log_file)
      restore_env("GITHUB_TOKEN", previous_github_token)
      File.rm_rf(workspace_root)
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

    snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)

    # Regression: rendering the visible operator message used to run get_in/2 on
    # an %AgentQueueItem{} struct, which crashed the whole Orchestrator GenServer
    # (structs don't implement Access). The struct's body map is reached directly now.
    refute snapshot == :timeout
    assert Process.alive?(pid)
    assert inspect(snapshot) =~ "hello operator text"
  end

  test "snapshot keeps legacy running entries with omitted optional Codex fields available" do
    orchestrator_name = Module.concat(__MODULE__, :LegacySnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    legacy_entry =
      running_entry("issue-legacy", "MT-LEGACY", :working)
      |> Map.drop([
        :session_id,
        :codex_app_server_pid,
        :agent_input_tokens,
        :agent_output_tokens,
        :agent_total_tokens,
        :last_codex_timestamp,
        :last_codex_message,
        :last_codex_event,
        :started_at
      ])

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-legacy" => legacy_entry}}
    end)

    assert %{running: [snapshot_entry]} = Orchestrator.snapshot(orchestrator_name, 5_000)
    assert snapshot_entry.identifier == "MT-LEGACY"
    assert snapshot_entry.session_id == nil
    assert snapshot_entry.codex_app_server_pid == nil
    assert snapshot_entry.runtime_seconds == 0
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
           ] = Orchestrator.status(orchestrator_name, 5_000)
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
           ] = Orchestrator.status(orchestrator_name, 5_000)
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
    assert_receive {:pause_agent, ^request_id, 1}, 500

    # Admission only proves routing. The authoritative state remains working
    # until evidence identifies this exact request and worker generation.
    assert [%{identifier: "repo#47", state: :running}] =
             wait_for_status(orchestrator_name, &match?([%{identifier: "repo#47", state: :running}], &1))

    send(pid, {:worker_control_state, "issue-round-trip", :paused, %{request_id: request_id, generation: 1}})

    assert [%{identifier: "repo#47", state: :paused}] =
             wait_for_status(orchestrator_name, &match?([%{identifier: "repo#47", state: :paused}], &1))

    assert {:ok, :resumed} = Orchestrator.resume_agent(orchestrator_name, "repo#47")
    assert_receive {:resume_agent, resume_request_id, 1} when is_integer(resume_request_id), 500

    assert [%{identifier: "repo#47", state: :paused}] =
             wait_for_status(orchestrator_name, &match?([%{identifier: "repo#47", state: :paused}], &1))

    send(pid, {:worker_control_state, "issue-round-trip", :working, %{request_id: resume_request_id, generation: 1}})

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
    assert_receive {:resume_agent, request_id, 1} when is_integer(request_id), 500
    assert %{active: 1, paused: 1, max: 2} = Orchestrator.max_concurrent_agents(orchestrator_name)

    send(pid, {:worker_control_state, "issue-paused", :working, %{request_id: request_id, generation: 1}})
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

    send(pid, {:worker_control_state, "issue-clock", :paused, %{kind: :agent_pause_request}})
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
    assert_receive {:resume_agent, request_id, 1} when is_integer(request_id), 500
    assert %{active: 0, paused: 1, max: 1} = Orchestrator.max_concurrent_agents(orchestrator_name)

    send(pid, {:worker_control_state, "issue-paused", :working, %{request_id: request_id, generation: 1}})
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

  test "running execution facts stay pinned while undispatched routing follows config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_routing: %{3 => "codex:gpt-5.6-terra:high"}
    )

    running_issue = %Issue{
      id: "issue-pinned-execution",
      identifier: "MT-PINNED",
      state: "In Progress",
      labels: ["complexity:3"]
    }

    idle_issue = %Issue{
      id: "issue-undispatched-execution",
      identifier: "MT-UNDISPATCHED",
      state: "Todo",
      labels: ["complexity:3"]
    }

    orchestrator_name = Module.concat(__MODULE__, :PinnedExecutionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            running_issue.id =>
              running_entry(
                running_issue.id,
                running_issue.identifier,
                :working
              )
              |> Map.put(:issue, running_issue)
          },
          last_polled_issues: %{idle_issue.id => idle_issue}
      }
    end)

    assert %{running: [warming], idle: [undispatched]} =
             Orchestrator.snapshot(orchestrator_name, 5_000)

    assert warming.backend == nil
    assert warming.requested_model == nil
    assert warming.effort == nil
    assert undispatched.backend == "codex"
    assert undispatched.requested_model == "gpt-5.6-terra"
    assert undispatched.effort == "high"

    send(
      pid,
      {:session_execution_info, running_issue.id, %{backend: "codex", requested_model: "gpt-5.6-terra", effort: "high"}}
    )

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_routing: %{3 => "claude:sonnet"}
    )

    assert %{running: [running], idle: [rerouted]} =
             Orchestrator.snapshot(orchestrator_name, 5_000)

    assert running.backend == "codex"
    assert running.agent_family == "codex"
    assert running.requested_model == "gpt-5.6-terra"
    assert running.effort == "high"
    assert rerouted.backend == "claude"
    assert rerouted.requested_model == "sonnet"
    assert rerouted.effort == nil
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
               error: "agent exited: :boom",
               priority: nil,
               progress_percent: 0
             }
           ] = snapshot.retrying

    assert due_in_ms > 0

    # No issue was ever polled for "mt-500", so its upstream list is unknown
    # rather than empty. `nil` is what makes the Stream Deck render the key
    # `Blocked`; an `[]` here would read as "no dependencies" and render it
    # `Unblocked` off data we never resolved.
    assert [%{blocked_by: nil}] = snapshot.retrying
  end

  test "status API, snapshot, and PubSub retain exact tracker identities" do
    orchestrator_name = Module.concat(__MODULE__, :TrackerIdentityOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    running_identity = tracker_identity("MT-701")
    retry_identity = tracker_identity("MT-702")
    idle_identity = tracker_identity("MT-703")

    running =
      "issue-running"
      |> running_entry("MT-701", :working)
      |> put_in([:issue, Access.key(:tracker_identity)], running_identity)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-running" => running},
          retry_attempts: %{
            "issue-retrying" => %{
              attempt: 1,
              timer_ref: nil,
              due_at_ms: System.monotonic_time(:millisecond) + 5_000,
              identifier: "MT-702",
              tracker_identity: retry_identity
            }
          },
          last_polled_issues: %{
            "issue-running" => %Issue{
              id: "issue-running",
              identifier: "MT-701",
              state: "in-progress",
              tracker_identity: running_identity
            },
            "issue-retrying" => %Issue{
              id: "issue-retrying",
              identifier: "MT-702",
              state: "in-progress",
              tracker_identity: retry_identity
            },
            "issue-idle" => %Issue{
              id: "issue-idle",
              identifier: "MT-703",
              state: "todo",
              tracker_identity: idle_identity
            }
          }
      }
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)
    assert [%{tracker_identity: ^running_identity}] = snapshot.running
    assert [%{tracker_identity: ^retry_identity}] = snapshot.retrying
    assert [%{tracker_identity: ^idle_identity}] = snapshot.idle

    assert %{tracker_identity: ^running_identity} =
             Enum.find(Orchestrator.status(orchestrator_name, 5_000), &(&1.identifier == "MT-701"))

    assert %{tracker_identity: ^retry_identity} =
             Enum.find(Orchestrator.status(orchestrator_name, 5_000), &(&1.identifier == "MT-702"))

    assert %{tracker_identity: ^idle_identity} =
             Enum.find(Orchestrator.status(orchestrator_name, 5_000), &(&1.identifier == "MT-703"))

    :ok = AgentPubSub.subscribe_running()
    :ok = StatusReport.notify_dashboard(:sys.get_state(pid))
    assert_receive {:running_changed, summaries}

    assert %{tracker_identity: ^running_identity} =
             Enum.find(summaries, &(&1.identifier == "MT-701"))

    assert %{tracker_identity: ^retry_identity} =
             Enum.find(summaries, &(&1.identifier == "MT-702"))

    assert %{tracker_identity: ^idle_identity} =
             Enum.find(summaries, &(&1.identifier == "MT-703"))
  end

  test "status snapshots do not overwrite current identity from a same-number retry" do
    orchestrator_name = Module.concat(__MODULE__, :IdentityCollisionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    retry_identity = tracker_identity("42")

    current_identity =
      TrackerIdentity.unjoinable(:repository_mismatch,
        owner: "owner",
        repository: "repo",
        identifier: 42
      )

    legacy_identity = TrackerIdentity.unjoinable(:legacy, identifier: 42)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | retry_attempts: %{
            "issue-retrying" => %{
              attempt: 1,
              timer_ref: nil,
              due_at_ms: System.monotonic_time(:millisecond) + 5_000,
              identifier: "42",
              tracker_identity: retry_identity
            }
          },
          last_polled_issues: %{
            "issue-retrying" => %Issue{
              id: "issue-retrying",
              identifier: "42",
              state: "in-progress",
              tracker_identity: current_identity
            },
            "legacy-42" => %Issue{
              id: "legacy-42",
              identifier: "42",
              state: "todo",
              tracker_identity: legacy_identity
            }
          }
      }
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)
    assert [%{tracker_identity: ^current_identity}] = snapshot.retrying
    assert [%{issue_id: "legacy-42", tracker_identity: ^legacy_identity}] = snapshot.idle

    statuses = Orchestrator.status(orchestrator_name, 5_000)

    assert %{tracker_identity: ^current_identity} =
             Enum.find(statuses, &(&1.issue_id == "issue-retrying"))

    assert %{tracker_identity: ^legacy_identity} =
             Enum.find(statuses, &(&1.issue_id == "legacy-42"))
  end

  test "orchestrator snapshot includes idle rows and explicit waiting reasons" do
    orchestrator_name = Module.concat(__MODULE__, :FleetStateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    stale_entry =
      "issue-stale"
      |> running_entry("MT-600", :working)
      |> Map.put(:last_codex_timestamp, DateTime.add(DateTime.utc_now(), -10 * 24 * 60 * 60, :second))
      |> Map.merge(%{codex_app_server_pid: nil, last_codex_message: nil, last_codex_event: nil})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-stale" => stale_entry},
          retry_attempts: %{
            "issue-retrying" => %{
              attempt: 1,
              timer_ref: nil,
              due_at_ms: System.monotonic_time(:millisecond) + 5_000,
              identifier: "MT-602"
            }
          },
          last_polled_issues: %{
            "issue-stale" => %Issue{id: "issue-stale", identifier: "MT-600", state: "In Progress"},
            "issue-ci-wait" => %Issue{
              id: "issue-ci-wait",
              identifier: "MT-601",
              state: "ci-wait",
              title: "Waiting on CI"
            },
            "issue-retrying" => %Issue{id: "issue-retrying", identifier: "MT-602", state: "In Progress"}
          }
      }
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)

    assert [%{identifier: "MT-600", waiting_reason: :unresponsive, stale_for_seconds: stale_for_seconds}] =
             snapshot.running

    assert stale_for_seconds > 24 * 60 * 60

    # A tracker-active issue already shown in the retry-backoff bucket must
    # not also double up as an idle row.
    assert [%{identifier: "MT-601", state: "ci-wait", waiting_reason: :waiting_for_ci}] = snapshot.idle
  end

  test "orchestrator snapshot reads open decisions without calling the per-ticket store" do
    identifier = "MT-ATTENTION-#{System.unique_integer([:positive])}"
    issue_id = "issue-attention-#{System.unique_integer([:positive])}"
    orchestrator_name = Module.concat(__MODULE__, :NonblockingFleetStateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      SubscriptionStore.stop(identifier)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :ok = SubscriptionStore.attach(identifier)
    :ok = SubscriptionStore.add_attention(identifier, "operator-decision")
    [{store_pid, 1}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, identifier)

    entry =
      issue_id
      |> running_entry(identifier, :working)
      |> Map.merge(%{
        codex_app_server_pid: nil,
        last_codex_timestamp: DateTime.add(DateTime.utc_now(), -10 * 24 * 60 * 60, :second),
        last_codex_message: nil,
        last_codex_event: nil
      })

    :sys.replace_state(pid, fn state -> %{state | running: %{issue_id => entry}} end)
    :ok = :sys.suspend(store_pid)

    try do
      assert %{running: [row]} = Orchestrator.snapshot(orchestrator_name, 5_000)
      assert row.open_decision_count == 1
      assert row.waiting_reason == :waiting_for_human
    after
      :ok = :sys.resume(store_pid)
    end
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
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    :ok = ActiveTurns.put("MT-CHAT", "turn-chat")

    on_exit(fn ->
      ActiveTurns.mark_closed("MT-CHAT", "turn-chat", :test_cleanup)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    parent = self()

    assert %{next_poll_due_at_ms: nil, tick_timer_ref: nil} = :sys.get_state(pid)

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
              issue: %Issue{
                id: "issue-chat",
                identifier: "MT-CHAT",
                state: "In Progress",
                tracker_identity: tracker_identity("MT-CHAT")
              },
              control: %{
                can_interrupt: true,
                safe_checkpoints: [:notification, :tool_result],
                application_confirmation: :confirmed,
                generation: 1,
                version: 0,
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
             OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-CHAT")

    assert {:ok,
            %{
              accepts_operator_messages: true,
              can_interrupt: true,
              accepted_delivery_policies: [:checkpoint, :interrupt],
              queue_depth: 0
            }} = Orchestrator.control_capabilities(orchestrator_name, "MT-CHAT")

    assert {:ok, pause_request_id} = Orchestrator.pause_agent(orchestrator_name, "MT-CHAT")
    assert_receive {:pause_agent, ^pause_request_id, _generation}

    assert {:ok, interrupt_request_id} =
             Orchestrator.send_operator_message(
               orchestrator_name,
               "MT-CHAT",
               %{kind: :text, body: "stop now", delivery_policy: :interrupt}
             )

    assert is_integer(interrupt_request_id)

    checkpoint_result = Orchestrator.claim_next_checkpoint_queue_item(orchestrator_name, "MT-CHAT")
    assert Process.alive?(pid)
    assert :empty = checkpoint_result

    assert {:ok,
            %{
              id: ^interrupt_request_id,
              category: :operator_message,
              delivery: %{interrupt_requested: true, priority: :now}
            }} =
             OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-CHAT")

    assert {:error, :empty_message} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-CHAT", %{kind: :text, body: "   "})

    assert {:error, :no_running_agent} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-MISSING", %{kind: :text, body: "hello"})
  end

  test "orchestrator records queued evidence before notifying the worker" do
    orchestrator_name = Module.concat(__MODULE__, :QueuedEvidenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    parent = self()

    worker_pid =
      spawn(fn ->
        :ok = AgentPubSub.subscribe_agent("MT-QUEUED-EVIDENCE")
        send(parent, :queued_evidence_worker_ready)

        for position <- [:first, :second] do
          receive do
            message -> send(parent, {:queued_evidence_worker_message, position, message})
          end
        end
      end)

    assert_receive :queued_evidence_worker_ready

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-queued-evidence" =>
              running_entry(
                "issue-queued-evidence",
                "MT-QUEUED-EVIDENCE",
                :working,
                worker_pid
              )
          }
      }
    end)

    assert {:ok, request_id} =
             Orchestrator.send_operator_message(
               orchestrator_name,
               "MT-QUEUED-EVIDENCE",
               %{kind: :text, body: "authoritative rework"}
             )

    assert_receive {:queued_evidence_worker_message, :first,
                    {:transcript_event,
                     %{
                       role: :user,
                       body: "authoritative rework",
                       payload: %{
                         operator_message: %{request_id: ^request_id, status: :queued}
                       }
                     }}}

    assert_receive {:queued_evidence_worker_message, :second, {:agent_queue_updated, "MT-QUEUED-EVIDENCE", ^request_id, _deliver_now?}}
  end

  test "provider acknowledgements clear only matching lifecycle fence items" do
    orchestrator_name = Module.concat(__MODULE__, :ProviderDeliveryFenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    :ok = AgentPubSub.subscribe_agent("MT-FENCE")
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-fence" => running_entry("issue-fence", "MT-FENCE", :working, parent)
          }
      }
    end)

    assert {:ok, first_id} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-FENCE", %{
               kind: :text,
               body: "first review instruction"
             })

    assert {:ok, second_id} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-FENCE", %{
               kind: :text,
               body: "second review instruction"
             })

    state = :sys.get_state(pid)

    assert state.running["issue-fence"].lifecycle_fence.pending_item_ids ==
             MapSet.new([first_id, second_id])

    assert {:ok, %{id: ^first_id}} =
             Orchestrator.claim_next_queue_item(orchestrator_name, "MT-FENCE")

    assert OperatorMessages.pending_operator_messages_for_issue(
             :sys.get_state(pid),
             "MT-FENCE"
           ) == [
             %{id: first_id, text: "first review instruction", status: :queued},
             %{id: second_id, text: "second review instruction", status: :queued}
           ]

    assert :ok =
             Orchestrator.acknowledge_queue_item_delivery(
               orchestrator_name,
               first_id,
               %{turn_id: "provider-turn-1"}
             )

    state = :sys.get_state(pid)

    assert state.running["issue-fence"].lifecycle_fence.pending_item_ids ==
             MapSet.new([second_id])

    assert_receive {:transcript_event,
                    %{
                      role: :system,
                      payload: %{
                        operator_message: %{
                          request_id: ^first_id,
                          status: :delivered,
                          provider_turn_id: "provider-turn-1"
                        }
                      }
                    }}

    assert {:ok, %{id: ^second_id}} =
             Orchestrator.claim_next_queue_item(orchestrator_name, "MT-FENCE")

    assert :ok =
             Orchestrator.acknowledge_queue_item_delivery(
               orchestrator_name,
               second_id,
               %{turn_id: "provider-turn-2"}
             )

    refute Map.has_key?(:sys.get_state(pid).running["issue-fence"], :lifecycle_fence)

    assert OperatorMessages.pending_operator_messages_for_issue(
             :sys.get_state(pid),
             "MT-FENCE"
           ) == [
             %{id: first_id, text: "first review instruction", status: :delivered},
             %{id: second_id, text: "second review instruction", status: :delivered}
           ]

    assert {:ok, failed_id} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-FENCE", %{
               kind: :text,
               body: "delivery will fail"
             })

    assert {:ok, %{id: ^failed_id}} =
             Orchestrator.claim_next_queue_item(orchestrator_name, "MT-FENCE")

    assert :ok =
             Orchestrator.mark_queue_item_failed(
               orchestrator_name,
               failed_id,
               :provider_down
             )

    state = :sys.get_state(pid)
    assert state.running["issue-fence"].lifecycle_fence.pending_item_ids == MapSet.new([failed_id])

    assert List.last(OperatorMessages.pending_operator_messages_for_issue(state, "MT-FENCE")) == %{id: failed_id, text: "delivery will fail", status: :failed}
  end

  test "provider acknowledgement clears every fence item folded into one event digest" do
    orchestrator_name = Module.concat(__MODULE__, :CoalescedFenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-coalesced-fence" =>
              running_entry(
                "issue-coalesced-fence",
                "MT-COALESCED-FENCE",
                :working,
                parent
              )
          }
      }
    end)

    for event_id <- [101, 102] do
      assert :ok =
               GenServer.call(orchestrator_name, {
                 :enqueue_event_digest,
                 "MT-COALESCED-FENCE",
                 %{
                   id: event_id,
                   topic: "ticket.MT-COALESCED-FENCE.issue.commented",
                   source: :github,
                   author_trusted?: true,
                   comment: %{id: event_id, body: "authoritative review #{event_id}"}
                 }
               })
    end

    assert_receive {:agent_queue_updated, "MT-COALESCED-FENCE", first_id, _deliver_now?}
    assert_receive {:agent_queue_updated, "MT-COALESCED-FENCE", second_id, _deliver_now?}

    state = :sys.get_state(pid)

    assert state.running["issue-coalesced-fence"].lifecycle_fence.pending_item_ids ==
             MapSet.new([first_id, second_id])

    assert {:ok, item} =
             Orchestrator.claim_next_queue_item(
               orchestrator_name,
               "MT-COALESCED-FENCE"
             )

    assert item.delivery.coalesced_item_ids == [first_id, second_id]

    assert :ok =
             QueueDrain.acknowledge_provider_delivery(
               orchestrator_name,
               item,
               %{turn_id: "provider-turn-coalesced"}
             )

    refute Map.has_key?(
             :sys.get_state(pid).running["issue-coalesced-fence"],
             :lifecycle_fence
           )
  end

  test "correlated operator messages return queue snapshots and notify only on enqueue or failed retry" do
    orchestrator_name = Module.concat(__MODULE__, :CorrelatedOperatorMessageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()
    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-occ" => running_entry("issue-occ", "MT-OCC", :working, worker_pid)}}
    end)

    correlation = %{
      decision_id: "dec_123",
      decision_version: 1,
      action_id: "act_123",
      actor: %{kind: :operator, id: "operator-1"}
    }

    payload = %{
      kind: :text,
      body: "Decision dec_123 answered: ship",
      action_id: "act_123",
      correlation: correlation
    }

    assert {:ok, %{status: :accepted, item: accepted}} =
             Orchestrator.send_correlated_operator_message(orchestrator_name, "MT-OCC", payload)

    assert accepted.status == :pending
    assert accepted.correlation == correlation
    assert_receive {:agent_queue_updated, "MT-OCC", accepted_id, _}
    assert accepted_id == accepted.id

    running = :sys.get_state(pid).running
    :sys.replace_state(pid, &%{&1 | running: %{}})

    assert {:ok, %{status: :duplicate, item: duplicate}} =
             Orchestrator.send_correlated_operator_message(orchestrator_name, "MT-OCC", payload)

    assert duplicate.id == accepted.id
    refute_receive {:agent_queue_updated, "MT-OCC", _, _}, 100

    :sys.replace_state(pid, &%{&1 | running: running})

    assert {:ok, delivered} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-OCC")
    assert :ok = OperatorMessages.mark_queue_item_failed(orchestrator_name, delivered.id, :agent_unavailable)

    assert {:ok, %{status: :retried, item: retried}} =
             Orchestrator.send_correlated_operator_message(
               orchestrator_name,
               "MT-OCC",
               Map.put(payload, :retry_failed, true)
             )

    assert retried.id == accepted.id
    assert retried.status == :pending
    assert_receive {:agent_queue_updated, "MT-OCC", retried_id, _}
    assert retried_id == accepted.id

    assert {:error, {:idempotency_conflict, "act_123"}} =
             Orchestrator.send_correlated_operator_message(
               orchestrator_name,
               "MT-OCC",
               Map.put(payload, :body, "Decision dec_123 answered differently")
             )
  end

  test "event digest wakes a sleeping agent task" do
    orchestrator_name = Module.concat(__MODULE__, :SleepingEventDigestOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-sleeping" => running_entry("issue-sleeping", "MT-SLEEP", :sleeping, worker_pid)}}
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-SLEEP",
               %{
                 topic: "ticket.MT-SLEEP.pr.review_comment",
                 source: :github,
                 author_trusted?: true,
                 message: "please fix",
                 comment: %{"body" => "please fix"}
               }
             })

    assert_receive {:agent_queue_updated, "MT-SLEEP", item_id, true}

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              body: %{events: [%{message: "please fix", comment: %{"body" => "please fix"}}]},
              delivery: %{interrupt_requested: true, priority: :now}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-SLEEP")
  end

  test "event digest does not auto-wake a manually paused agent task" do
    orchestrator_name = Module.concat(__MODULE__, :PausedEventDigestOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused, worker_pid)}}
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-PAUSED",
               %{
                 topic: "ticket.MT-PAUSED.pr.review_comment",
                 source: :github,
                 author_trusted?: true,
                 message: "please fix",
                 comment: %{"body" => "please fix"}
               }
             })

    assert_receive {:agent_queue_updated, "MT-PAUSED", item_id, false}

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: false, priority: :later}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-PAUSED")
  end

  test "system default-branch push wakes a sleeping (standby) agent task" do
    orchestrator_name = Module.concat(__MODULE__, :SleepingMainPushOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-main-sleep" => running_entry("issue-main-sleep", "MT-MAIN-SLEEP", :sleeping, worker_pid)
          }
      }
    end)

    # Same path a real push takes: each agent's SubscriptionStore enqueues the
    # `system.<base>.branch.push` it is universally subscribed to.
    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-MAIN-SLEEP",
               %{topic: "system.main.branch.push", sha: "abc123", message: "main advanced"}
             })

    # Standby agent is woken so it can pull main and resume in its held slot.
    assert_receive {:agent_queue_updated, "MT-MAIN-SLEEP", item_id, true}

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: true, priority: :now}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-MAIN-SLEEP")
  end

  test "system default-branch push does not wake a manually paused agent task" do
    orchestrator_name = Module.concat(__MODULE__, :PausedMainPushOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-main-paused" => running_entry("issue-main-paused", "MT-MAIN-PAUSED", :paused, worker_pid)
          }
      }
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-MAIN-PAUSED",
               %{topic: "system.main.branch.push", sha: "abc123", message: "main advanced"}
             })

    # A manual pause is never woken by a main update; the notice waits in queue
    # until the operator resumes.
    assert_receive {:agent_queue_updated, "MT-MAIN-PAUSED", item_id, false}

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: false, priority: :later}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-MAIN-PAUSED")
  end

  test "system default-branch push does not interrupt a working agent mid-turn" do
    orchestrator_name = Module.concat(__MODULE__, :WorkingMainPushOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      ActiveTurns.mark_closed("MT-MAIN-WORK", "turn-active", :test_cleanup)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)
    :ok = ActiveTurns.put("MT-MAIN-WORK", "turn-active")

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-main-work" => running_entry("issue-main-work", "MT-MAIN-WORK", :working, worker_pid)
          }
      }
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-MAIN-WORK",
               %{topic: "system.main.branch.push", sha: "abc123", message: "main advanced"}
             })

    # The headline acceptance criterion: a main update never interrupts an
    # in-flight turn. The notice is queued NON-interrupting and seen at the next
    # turn boundary, leaving whether/when to pull main to the agent.
    assert_receive {:agent_queue_updated, "MT-MAIN-WORK", item_id, false}

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: false, priority: :later}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-MAIN-WORK")
  end

  test "event digest wakes a running agent with no active turn" do
    orchestrator_name = Module.concat(__MODULE__, :IdleEventDigestOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-idle-turn" => running_entry("issue-idle-turn", "MT-IDLE-TURN", :working, worker_pid)}}
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-IDLE-TURN",
               %{topic: "ticket.MT-IDLE-TURN.pr.review_comment", comment: %{body: "please fix"}}
             })

    assert_receive {:agent_queue_updated, "MT-IDLE-TURN", item_id, true}

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: true, priority: :now}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-IDLE-TURN")
  end

  test "untrusted event digest keeps checkpoint delivery while a turn is active" do
    orchestrator_name = Module.concat(__MODULE__, :UntrustedActiveEventDigestOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      ActiveTurns.mark_closed("MT-WORK", "turn-active", :test_cleanup)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)
    :ok = ActiveTurns.put("MT-WORK", "turn-active")

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-working" => running_entry("issue-working", "MT-WORK", :working, worker_pid)}}
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-WORK",
               %{topic: "ticket.MT-WORK.pr.review_comment", comment: %{body: "please fix"}}
             })

    assert_receive {:agent_queue_updated, "MT-WORK", item_id, false}

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: false, priority: :later}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-WORK")
  end

  test "trusted PR review comment wakes a running agent with an active turn" do
    orchestrator_name = Module.concat(__MODULE__, :TrustedActiveReviewCommentOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      ActiveTurns.mark_closed("MT-WORK-REVIEW", "turn-active-review", :test_cleanup)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)
    :ok = ActiveTurns.put("MT-WORK-REVIEW", "turn-active-review")

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-working-review" => running_entry("issue-working-review", "MT-WORK-REVIEW", :working, worker_pid)}}
    end)

    assert :ok =
             GenServer.call(orchestrator_name, {
               :enqueue_event_digest,
               "MT-WORK-REVIEW",
               %{
                 topic: "ticket.MT-WORK-REVIEW.pr.review_comment",
                 source: :github,
                 author_trusted?: true,
                 comment: %{body: "please fix"}
               }
             })

    assert_receive {:agent_queue_updated, "MT-WORK-REVIEW", item_id, true}

    assert {:ok,
            %{
              id: ^item_id,
              category: :coordination_event,
              delivery: %{interrupt_requested: true, priority: :now}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-WORK-REVIEW")
  end

  test "operator message wakes a running agent with no active turn" do
    orchestrator_name = Module.concat(__MODULE__, :SleepingOperatorMessageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid = spawn(fn -> operator_message_probe(parent) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-sleeping-chat" => running_entry("issue-sleeping-chat", "MT-SLEEP-CHAT", :sleeping, worker_pid)}}
    end)

    assert {:ok, request_id} =
             Orchestrator.send_operator_message(orchestrator_name, "MT-SLEEP-CHAT", %{
               kind: :text,
               body: "please address the review"
             })

    assert_receive {:agent_queue_updated, "MT-SLEEP-CHAT", ^request_id, true}

    assert {:ok,
            %{
              id: ^request_id,
              category: :operator_message,
              delivery: %{interrupt_requested: false, priority: :next}
            }} = OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-SLEEP-CHAT")
  end

  test "completed runner releases its slot and an Executor message schedules replacement" do
    orchestrator_name = Module.concat(__MODULE__, :CompletedOperatorMessageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    freeze_poll_cycle(pid)
    parent = self()
    {:ok, old_worker} = supervised_operator_message_probe(parent)
    old_ref = Process.monitor(old_worker)

    issue =
      %Issue{
        id: "issue-completed",
        identifier: "MT-COMPLETED",
        state: "rework",
        title: "Completed message replacement"
      }

    release_file = configure_completed_revalidation!([issue])

    on_exit(fn ->
      File.touch(release_file)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(old_worker), do: Process.exit(old_worker, :kill)
    end)

    :sys.replace_state(pid, fn state ->
      entry =
        "issue-completed"
        |> running_entry("MT-COMPLETED", :working, old_worker)
        |> Map.put(:ref, old_ref)
        |> Map.put(:issue, issue)

      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{"issue-completed" => entry},
          claimed: MapSet.put(state.claimed, "issue-completed")
      }
    end)

    send(pid, {:worker_control_state, "issue-completed", :completed})

    assert %{active: 0} = Orchestrator.max_concurrent_agents(orchestrator_name)

    assert %{running: [%{work_state: :completed, waiting_reason: :awaiting_dispatch}]} =
             GenServer.call(orchestrator_name, :snapshot)

    assert {:error, :already_inactive} = Orchestrator.pause_agent(orchestrator_name, "MT-COMPLETED")

    item_ids =
      for body <- ["first repair", "second repair", "third repair"] do
        assert {:ok, item_id} =
                 Orchestrator.send_operator_message(orchestrator_name, "MT-COMPLETED", %{
                   kind: :text,
                   body: body
                 })

        item_id
      end

    refute Process.alive?(old_worker)

    state = :sys.get_state(pid)
    replacement = Map.fetch!(state.running, "issue-completed")

    assert is_pid(replacement.pid)
    assert Process.alive?(replacement.pid)
    assert replacement.pid != old_worker
    assert is_reference(replacement.ref)
    assert replacement.ref != old_ref
    assert replacement.control.status == :working
    assert state.queue_store.pending_ids_by_target["MT-COMPLETED"] == item_ids

    assert Enum.map(item_ids, &state.queue_store.items[&1].body.text) == [
             "first repair",
             "second repair",
             "third repair"
           ]

    send(pid, {:DOWN, old_ref, :process, old_worker, :normal})
    after_stale_down = :sys.get_state(pid)

    assert after_stale_down.running["issue-completed"].pid == replacement.pid
    assert after_stale_down.running["issue-completed"].ref == replacement.ref
    refute Map.has_key?(after_stale_down.retry_attempts, "issue-completed")
  end

  test "explicit resume replaces a completed runner instead of waking its returned task" do
    orchestrator_name = Module.concat(__MODULE__, :CompletedResumeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    freeze_poll_cycle(pid)
    {:ok, old_worker} = supervised_operator_message_probe(self())
    old_ref = Process.monitor(old_worker)

    issue = %Issue{
      id: "issue-completed-resume",
      identifier: "MT-COMPLETED-RESUME",
      state: "rework",
      title: "Completed explicit resume"
    }

    release_file = configure_completed_revalidation!([issue])

    on_exit(fn ->
      File.touch(release_file)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(old_worker), do: Process.exit(old_worker, :kill)
    end)

    :sys.replace_state(pid, fn state ->
      entry =
        "issue-completed-resume"
        |> running_entry("MT-COMPLETED-RESUME", :completed, old_worker)
        |> Map.put(:ref, old_ref)
        |> Map.put(:issue, issue)

      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{"issue-completed-resume" => entry},
          claimed: MapSet.put(state.claimed, "issue-completed-resume")
      }
    end)

    assert {:ok, :started} = Orchestrator.resume_agent(orchestrator_name, "MT-COMPLETED-RESUME")
    refute Process.alive?(old_worker)

    state = :sys.get_state(pid)
    replacement = Map.fetch!(state.running, "issue-completed-resume")
    assert is_pid(replacement.pid)
    assert Process.alive?(replacement.pid)
    assert replacement.pid != old_worker
    assert is_reference(replacement.ref)
    assert replacement.ref != old_ref
    refute Map.has_key?(state.retry_attempts, "issue-completed-resume")
  end

  test "tracker revalidation retains completed runners and messages for inactive states" do
    current_issues = [
      %Issue{id: "inactive-review", identifier: "MT-INACTIVE-REVIEW", state: "human-review", title: "Review"},
      %Issue{id: "inactive-ci", identifier: "MT-INACTIVE-CI", state: "ci-wait", title: "CI"},
      %Issue{id: "inactive-done", identifier: "MT-INACTIVE-DONE", state: "done", title: "Done"},
      %Issue{id: "inactive-paused", identifier: "MT-INACTIVE-PAUSED", state: "rework", title: "Paused", paused: true}
    ]

    release_file = configure_completed_revalidation!(current_issues)

    completed =
      Map.new(current_issues, fn current_issue ->
        {:ok, worker} = supervised_operator_message_probe(self())
        ref = Process.monitor(worker)
        cached_issue = %{current_issue | state: "rework", paused: false}

        entry =
          current_issue.id
          |> running_entry(current_issue.identifier, :completed, worker)
          |> Map.put(:ref, ref)
          |> Map.put(:issue, cached_issue)

        {current_issue.id, {worker, ref, entry}}
      end)

    on_exit(fn ->
      File.touch(release_file)

      Enum.each(completed, fn {_issue_id, {worker, _ref, _entry}} ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)
      end)
    end)

    entries = Map.new(completed, fn {issue_id, {_worker, _ref, entry}} -> {issue_id, entry} end)

    initial_state = %State{
      running: entries,
      claimed: MapSet.new(Map.keys(entries)),
      max_concurrent_agents: 4
    }

    {item_ids, state} =
      Enum.reduce(current_issues, {%{}, initial_state}, fn issue, {ids, state} ->
        assert {{:ok, item_id}, next_state} =
                 OperatorMessages.enqueue_operator_message(
                   state,
                   issue.identifier,
                   "retain #{issue.id}",
                   %{}
                 )

        {Map.put(ids, issue.id, item_id), next_state}
      end)

    Enum.each(current_issues, fn current_issue ->
      {worker, ref, original_entry} = completed[current_issue.id]
      retained = Map.fetch!(state.running, current_issue.id)

      assert Process.alive?(worker)
      assert retained.pid == worker
      assert retained.ref == ref
      assert retained.control.status == :completed
      assert retained.session_id == original_entry.session_id
      assert retained.worker_host == original_entry.worker_host
      assert retained.issue.state == current_issue.state
      assert retained.issue.paused == current_issue.paused
      assert MapSet.member?(state.claimed, current_issue.id)
      assert state.queue_store.pending_ids_by_target[current_issue.identifier] == [item_ids[current_issue.id]]
      refute Map.has_key?(state.retry_attempts, current_issue.id)
    end)
  end

  test "failed admitted spawn restores the completed row, claim, identity, and FIFO queue" do
    issue = %Issue{
      id: "spawn-failure-completed",
      identifier: "MT-SPAWN-FAILURE",
      state: "rework",
      title: "Retain completed spawn failure"
    }

    {:ok, old_worker} = supervised_operator_message_probe(self())
    old_ref = Process.monitor(old_worker)

    on_exit(fn ->
      if Process.alive?(old_worker), do: Process.exit(old_worker, :kill)
    end)

    entry =
      issue.id
      |> running_entry(issue.identifier, :completed, old_worker, "worker-a")
      |> Map.put(:ref, old_ref)
      |> Map.put(:issue, issue)
      |> Map.put(:session_id, "thread-preserved")
      |> Map.put(:started_at, DateTime.add(DateTime.utc_now(), -30, :second))

    {queue_store, first} =
      AgentQueueStore.enqueue(%AgentQueueStore{}, %{
        target_issue_identifier: issue.identifier,
        source: :operator,
        category: :operator_message,
        event_type: :operator_message,
        body: %{text: "first"}
      })

    {queue_store, second} =
      AgentQueueStore.enqueue(queue_store, %{
        target_issue_identifier: issue.identifier,
        source: :operator,
        category: :operator_message,
        event_type: :operator_message,
        body: %{text: "second"}
      })

    state = %State{
      running: %{issue.id => entry},
      claimed: MapSet.new([issue.id]),
      queue_store: queue_store,
      max_concurrent_agents: 2
    }

    spawn_failure = fn torn_state, _issue, _attempt, _worker_host ->
      %{torn_state | retry_attempts: %{issue.id => %{attempt: 1}}}
    end

    next =
      PauseResume.replace_admitted_completed_entry(
        state,
        entry,
        issue,
        "worker-a",
        spawn_failure
      )

    refute Process.alive?(old_worker)
    restored = Map.fetch!(next.running, issue.id)
    assert restored.pid == nil
    assert restored.ref == nil
    assert restored.control.status == :completed
    assert restored.session_id == "thread-preserved"
    assert restored.worker_host == "worker-a"
    assert restored.completed_provenance
    assert restored.completion_totals_recorded
    assert MapSet.member?(next.claimed, issue.id)
    assert next.queue_store.pending_ids_by_target[issue.identifier] == [first.id, second.id]
    refute Map.has_key?(next.retry_attempts, issue.id)

    first_totals = next.agent_totals
    assert first_totals.seconds_running >= 30

    repeated =
      PauseResume.replace_admitted_completed_entry(
        next,
        restored,
        issue,
        "worker-a",
        spawn_failure
      )

    assert repeated.agent_totals == first_totals
    assert repeated.running[issue.id].completion_totals_recorded
    assert repeated.queue_store.pending_ids_by_target[issue.identifier] == [first.id, second.id]
  end

  test "tracker rework after completed CI wait honors effective capacity" do
    issue = completed_rework_issue("tracker-effective-cap")
    configure_completed_revalidation!([issue], max_concurrent_agents: 3)
    {state, parked_entry, worker, item_ids} = tracker_completed_retention_fixture(issue)

    other =
      "other-effective-cap"
      |> running_entry("MT-OTHER-EFFECTIVE-CAP", :working)
      |> Map.put(:issue, completed_rework_issue("other-effective-cap"))

    state = %{
      state
      | effective_concurrent_agents: 1,
        running: Map.put(state.running, "other-effective-cap", other)
    }

    next = Reconciler.maybe_reactivate_or_refresh(state, issue)

    assert_tracker_completed_preflight_retained(next, parked_entry, worker, item_ids)
  end

  test "tracker rework after completed CI wait honors the state cap" do
    issue = completed_rework_issue("state-cap")

    configure_completed_revalidation!([issue],
      max_concurrent_agents: 3,
      max_concurrent_agents_by_state: %{"rework" => 1}
    )

    {state, parked_entry, worker, item_ids} = tracker_completed_retention_fixture(issue)

    other =
      "other-state-cap"
      |> running_entry("MT-OTHER-STATE-CAP", :working)
      |> Map.put(:issue, completed_rework_issue("other-state-cap"))

    state = %{state | running: Map.put(state.running, "other-state-cap", other)}
    next = Reconciler.maybe_reactivate_or_refresh(state, issue)

    assert_tracker_completed_preflight_retained(next, parked_entry, worker, item_ids)
  end

  test "tracker rework after completed CI wait preserves the worker host gate" do
    issue = completed_rework_issue("host-cap")

    configure_completed_revalidation!([issue],
      max_concurrent_agents: 3,
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    {state, parked_entry, worker, item_ids} =
      tracker_completed_retention_fixture(issue, "worker-a")

    other =
      "other-host-cap"
      |> running_entry("MT-OTHER-HOST-CAP", :working, self(), "worker-a")
      |> Map.put(:issue, completed_rework_issue("other-host-cap"))

    state = %{state | running: Map.put(state.running, "other-host-cap", other)}
    next = Reconciler.maybe_reactivate_or_refresh(state, issue)

    assert_tracker_completed_preflight_retained(next, parked_entry, worker, item_ids)
  end

  test "tracker rework after completed CI wait honors the thrash gate" do
    issue = completed_rework_issue("thrash")
    configure_completed_revalidation!([issue], max_concurrent_agents: 3)
    {state, parked_entry, worker, item_ids} = tracker_completed_retention_fixture(issue)

    thrash_budget = %{
      issue.id => %{
        window_start_ms: System.monotonic_time(:millisecond),
        count: 100
      }
    }

    state = put_in(state.dispatch_recovery.codex_thrash_budget, thrash_budget)

    next = Reconciler.maybe_reactivate_or_refresh(state, issue)

    assert_tracker_completed_preflight_retained(next, parked_entry, worker, item_ids)
  end

  test "tracker rework after completed CI wait honors all-limited model admission" do
    issue = %{completed_rework_issue("all-limited") | selected_backend: nil}

    configure_completed_revalidation!([issue],
      max_concurrent_agents: 3,
      agent_routing: %{"4" => "claude"}
    )

    workflow_path = Workflow.workflow_file_path()
    workflow = File.read!(workflow_path)

    workflow =
      String.replace(
        workflow,
        "  turn_timeout_ms:",
        "  switch_model_on_ratelimit: [claude]\n  turn_timeout_ms:"
      )

    File.write!(workflow_path, workflow)
    WorkflowStore.force_reload()

    File.write!(
      Path.join(Path.dirname(workflow_path), "model-usage.json"),
      Jason.encode!(%{
        "backends" => %{
          "claude" => %{
            "limited" => true,
            "reset_at" => "2999-01-01T00:00:00Z"
          }
        }
      })
    )

    {state, parked_entry, worker, item_ids} = tracker_completed_retention_fixture(issue)
    next = Reconciler.maybe_reactivate_or_refresh(state, issue)

    assert_tracker_completed_preflight_retained(next, parked_entry, worker, item_ids)
  end

  test "tracker rework after completed human review uses hardened replacement" do
    active_issue = completed_rework_issue("human-review-provenance")
    review_issue = %{active_issue | state: "human-review"}
    configure_completed_revalidation!([active_issue], max_concurrent_agents: 3)
    previous_verifier = Application.get_env(:aiur, :human_review_ready_verifier)
    Application.put_env(:aiur, :human_review_ready_verifier, fn _issue_id -> :ok end)

    on_exit(fn ->
      restore_application_env(:human_review_ready_verifier, previous_verifier)
    end)

    {state, _entry, worker, item_ids} = completed_retention_fixture(review_issue)
    parked = HumanReview.maybe_deactivate_human_review_issue(state, review_issue)
    parked_entry = Map.fetch!(parked.running, active_issue.id)

    refute Process.alive?(worker)
    assert parked_entry.control.status == :deactivated
    assert parked_entry.completed_provenance
    assert parked_entry.completion_totals_recorded

    next = Reconciler.maybe_reactivate_or_refresh(parked, active_issue)
    replacement = Map.fetch!(next.running, active_issue.id)

    assert replacement.control.status == :working
    assert is_pid(replacement.pid) and Process.alive?(replacement.pid)
    assert is_reference(replacement.ref)
    assert replacement.worker_host == parked_entry.worker_host
    assert next.queue_store.pending_ids_by_target[active_issue.identifier] == item_ids
  end

  test "tracker poll unpause replaces a dead runner and reports running through the CLI" do
    active_issue = completed_rework_issue("paused-provenance")
    paused_issue = %{active_issue | paused: true}
    configure_completed_revalidation!([active_issue], max_concurrent_agents: 3)
    {state, _entry, worker, item_ids} = completed_retention_fixture(active_issue)

    paused = PauseResume.pause_issue_for_label_override(state, paused_issue)
    paused_entry = Map.fetch!(paused.running, active_issue.id)

    refute Process.alive?(worker)
    assert paused_entry.control.status == :paused
    assert paused_entry.paused_reason == :label_override
    assert paused_entry.completed_provenance
    assert paused_entry.completion_totals_recorded
    assert paused_entry.pid == nil
    assert paused_entry.ref == nil
    refute_received {:pause_agent, _request_id}

    assert PauseResume.pause_issue_for_label_override(paused, paused_issue) == paused

    orchestrator_pid = Process.whereis(Aiur.Orchestrator)
    original_state = :sys.get_state(orchestrator_pid)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: :sys.replace_state(orchestrator_pid, fn _state -> original_state end)
    end)

    next = Reconciler.refresh_running_issue_states(paused)
    replacement = Map.fetch!(next.running, active_issue.id)

    assert replacement.control.status == :working
    assert is_pid(replacement.pid) and Process.alive?(replacement.pid)
    assert is_reference(replacement.ref)
    assert next.queue_store.pending_ids_by_target[active_issue.identifier] == item_ids

    :sys.replace_state(orchestrator_pid, fn _state -> next end)

    assert capture_io(fn -> AgentControlCLI.status() end) =~
             "#{active_issue.identifier} running #{active_issue.title}"
  end

  test "Executor messages rearm multiple completed runners without returned workers holding slots" do
    orchestrator_name = Module.concat(__MODULE__, :CompletedBatchOperatorMessageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    freeze_poll_cycle(pid)
    parent = self()

    completed =
      for number <- 1..3, into: %{} do
        issue_id = "issue-completed-#{number}"
        identifier = "MT-COMPLETED-#{number}"
        {:ok, worker} = supervised_operator_message_probe(parent)
        ref = Process.monitor(worker)

        issue = %Issue{
          id: issue_id,
          identifier: identifier,
          state: "rework",
          title: "Completed batch #{number}"
        }

        entry =
          issue_id
          |> running_entry(identifier, :completed, worker)
          |> Map.put(:ref, ref)
          |> Map.put(:issue, issue)

        {issue_id, {identifier, worker, ref, entry}}
      end

    issues = Enum.map(completed, fn {_issue_id, {_identifier, _worker, _ref, entry}} -> entry.issue end)
    release_file = configure_completed_revalidation!(issues)

    on_exit(fn ->
      File.touch(release_file)
      if Process.alive?(pid), do: Process.exit(pid, :normal)

      Enum.each(completed, fn {_issue_id, {_identifier, worker, _ref, _entry}} ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)
      end)
    end)

    :sys.replace_state(pid, fn state ->
      entries =
        Map.new(completed, fn {issue_id, {_identifier, _worker, _ref, entry}} ->
          {issue_id, entry}
        end)

      %{
        state
        | session_max_concurrent_agents: 3,
          effective_concurrent_agents: 1,
          running: entries,
          claimed: MapSet.new(Map.keys(entries))
      }
    end)

    assert %{active: 0, max: 3} = Orchestrator.max_concurrent_agents(orchestrator_name)

    item_ids =
      for {issue_id, {identifier, _worker, _ref, _entry}} <- completed, into: %{} do
        assert {:ok, item_id} =
                 GenServer.call(
                   orchestrator_name,
                   {:send_operator_message, identifier, %{kind: :text, body: "rework #{issue_id}"}},
                   30_000
                 )

        {issue_id, item_id}
      end

    state = :sys.get_state(pid)

    working_entries =
      Enum.filter(state.running, fn {_issue_id, entry} ->
        get_in(entry, [:control, :status]) == :working
      end)

    completed_entries =
      Enum.filter(state.running, fn {_issue_id, entry} ->
        get_in(entry, [:control, :status]) == :completed
      end)

    assert length(working_entries) == 1
    assert length(completed_entries) == 2
    refute Map.keys(state.retry_attempts) |> Enum.any?(&Map.has_key?(completed, &1))

    Enum.each(completed, fn {issue_id, {_identifier, worker, old_ref, old_entry}} ->
      expected_body = "rework #{issue_id}"
      assert %{body: %{text: ^expected_body}} = state.queue_store.items[item_ids[issue_id]]

      entry = Map.fetch!(state.running, issue_id)

      if entry.control.status == :working do
        refute Process.alive?(worker)
        assert is_pid(entry.pid) and Process.alive?(entry.pid)
        assert is_reference(entry.ref)
        assert entry.ref != old_ref
      else
        assert entry.pid == worker
        assert entry.ref == old_ref
        assert entry.session_id == old_entry.session_id
        assert entry.worker_host == old_entry.worker_host
        assert MapSet.member?(state.claimed, issue_id)
      end
    end)
  end

  test "freezing the poll cycle fences a stale :run_poll_cycle so no live poll runs" do
    orchestrator_name = Module.concat(__MODULE__, :FrozenPollCycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    freeze_poll_cycle(pid)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    # The initial tick schedules a one-shot `:run_poll_cycle` (~20ms render
    # delay) that is not token-fenced; the freeze must make it (and any
    # explicit re-send) a no-op. A live poll always schedules a fresh tick via
    # `Lifecycle.schedule_tick/2`, so `tick_timer_ref` staying nil proves no
    # poll ran (and the load envelope was not re-armed).
    send(pid, :run_poll_cycle)
    Process.sleep(50)

    state = :sys.get_state(pid)
    assert state.tick_timer_ref == nil
    assert state.poll_frozen == true
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
    assert_receive {:agent_queue_updated, "MT-PAUSED", ^request_id, _delivery}, 500
    assert_receive {:resume_agent, resume_request_id, generation}, 500

    status = Orchestrator.max_concurrent_agents(orchestrator_name)
    assert status.active == 0
    assert status.paused == 1

    send(pid, {:worker_control_state, "issue-paused", :working, %{request_id: resume_request_id, generation: generation}})

    status = Orchestrator.max_concurrent_agents(orchestrator_name)
    assert status.active == 1
    assert status.paused == 0
  end

  test "a Decision answer is queued before its paused agent is resumed" do
    orchestrator_name = Module.concat(__MODULE__, :DecisionPausedQueueFirstOrchestrator)
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
            "issue-paused-decision" => running_entry("issue-paused-decision", "MT-DECISION", :paused, parent)
          }
      }
    end)

    payload = %{
      kind: :text,
      body: "Durable Executor answer for ticket MT-DECISION",
      action_id: "act_queue_first",
      correlation: %{
        decision_id: "dec_queue_first",
        decision_version: 1,
        action_id: "act_queue_first",
        actor: %{kind: :operator, id: "operator-1"}
      },
      delivery_policy: :interrupt,
      fallback: :queue_next
    }

    assert {:ok, %{status: :accepted, item: item}} =
             Orchestrator.send_correlated_operator_message(
               orchestrator_name,
               "MT-DECISION",
               payload
             )

    # Both signals come from the orchestrator process. Mailbox ordering proves
    # the durable input is visible before any worker wake can start a turn.
    assert_receive {:agent_queue_updated, "MT-DECISION", item_id, true}, 500
    assert item_id == item.id
    assert_receive {:resume_agent, _request_id, _generation}, 500

    assert %{id: ^item_id, action_id: "act_queue_first"} =
             :sys.get_state(pid).queue_store.items[item_id]
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
             OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-QUEUE")
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

    assert eventually?(fn ->
             state = :sys.get_state(pid)
             not Process.alive?(worker_pid) and not Map.has_key?(state.running, issue_id)
           end)

    state = :sys.get_state(pid)
    observed_at_ms = System.monotonic_time(:millisecond)

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
    status = Orchestrator.status(orchestrator_name, 5_000)

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

  # Polls the SnapshotStore read model until the periodic SnapshotPublisher has
  # projected a snapshot matching `predicate`, returning the full read result.
  defp wait_for_published_snapshot(orchestrator_name, predicate, timeout_ms \\ 5_000)
       when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_published_snapshot(orchestrator_name, predicate, deadline_ms)
  end

  defp do_wait_for_published_snapshot(orchestrator_name, predicate, deadline_ms) do
    result = Orchestrator.dashboard_snapshot(orchestrator_name, 1_000)

    case result do
      {:current, snapshot, _freshness} ->
        if predicate.(snapshot) do
          result
        else
          retry_published_snapshot(orchestrator_name, predicate, deadline_ms)
        end

      _not_yet_published ->
        retry_published_snapshot(orchestrator_name, predicate, deadline_ms)
    end
  end

  defp retry_published_snapshot(orchestrator_name, predicate, deadline_ms) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      flunk("timed out waiting for the publisher to project a fleet snapshot for #{inspect(orchestrator_name)}")
    else
      Process.sleep(25)
      do_wait_for_published_snapshot(orchestrator_name, predicate, deadline_ms)
    end
  end

  defp operator_message_probe(parent) do
    receive do
      message ->
        send(parent, message)
        operator_message_probe(parent)
    end
  end

  defp supervised_operator_message_probe(parent) do
    Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> operator_message_probe(parent) end)
  end

  defp freeze_poll_cycle(pid) do
    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        state
        | tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: nil,
          poll_check_in_progress: false,
          # The initial tick schedules a one-shot `:run_poll_cycle` (20ms render
          # delay) that is not token-fenced, so it can fire a live poll after
          # this freeze and ramp the load envelope mid-test. Fence it here.
          poll_frozen: true
      }
    end)
  end

  defp completed_rework_issue(suffix) do
    %Issue{
      id: "completed-#{suffix}",
      identifier: "MT-COMPLETED-#{String.upcase(suffix)}",
      state: "rework",
      title: "Completed #{suffix}",
      selected_backend: "claude"
    }
  end

  defp completed_retention_fixture(issue, worker_host \\ nil) do
    {:ok, worker} = supervised_operator_message_probe(self())
    worker_ref = Process.monitor(worker)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    entry =
      issue.id
      |> running_entry(issue.identifier, :completed, worker, worker_host)
      |> Map.put(:ref, worker_ref)
      |> Map.put(:issue, issue)
      |> Map.put(:session_id, "preserved-#{issue.id}")

    {queue_store, first} =
      AgentQueueStore.enqueue(%AgentQueueStore{}, %{
        target_issue_identifier: issue.identifier,
        source: :operator,
        category: :operator_message,
        event_type: :operator_message,
        body: %{text: "first"}
      })

    {queue_store, second} =
      AgentQueueStore.enqueue(queue_store, %{
        target_issue_identifier: issue.identifier,
        source: :operator,
        category: :operator_message,
        event_type: :operator_message,
        body: %{text: "second"}
      })

    state = %State{
      running: %{issue.id => entry},
      claimed: MapSet.new([issue.id]),
      queue_store: queue_store,
      max_concurrent_agents: 3
    }

    {state, entry, worker, [first.id, second.id]}
  end

  defp tracker_completed_retention_fixture(issue, worker_host \\ nil) do
    {state, _entry, worker, item_ids} = completed_retention_fixture(issue, worker_host)
    parked_issue = %{issue | state: "ci-wait"}
    parked = CiLifecycle.pause_issue_for_ci_wait(state, parked_issue)
    parked_entry = Map.fetch!(parked.running, issue.id)

    refute Process.alive?(worker)
    assert parked_entry.control.status == :deactivated
    assert parked_entry.completed_provenance
    assert parked_entry.completion_totals_recorded
    assert parked_entry.pid == nil
    assert parked_entry.ref == nil

    {parked, parked_entry, worker, item_ids}
  end

  defp assert_tracker_completed_preflight_retained(state, parked_entry, worker, item_ids) do
    issue = parked_entry.issue
    retained = Map.fetch!(state.running, issue.id)

    refute Process.alive?(worker)
    assert retained.pid == nil
    assert retained.ref == nil
    assert retained.control.status == :completed
    assert retained.completed_provenance
    assert retained.completion_totals_recorded
    assert retained.session_id == parked_entry.session_id
    assert retained.worker_host == parked_entry.worker_host
    assert MapSet.member?(state.claimed, issue.id)
    assert state.queue_store.pending_ids_by_target[issue.identifier] == item_ids
    refute Map.has_key?(state.retry_attempts, issue.id)
    refute Map.has_key?(state.ci_lifecycle.rewakes, issue.id)
  end

  defp configure_completed_revalidation!(issues, overrides \\ []) do
    previous_issues = Application.get_env(:aiur, :memory_tracker_issues)

    release_file =
      Path.join(
        System.tmp_dir!(),
        "completed-revalidation-#{System.unique_integer([:positive])}.release"
      )

    File.rm(release_file)

    config =
      Keyword.merge(
        [
          tracker_kind: "memory",
          tracker_active_states: ["in-progress", "rework"],
          tracker_terminal_states: ["done", "cancelled", "canceled"],
          hook_before_run: "while [ ! -f #{release_file} ]; do sleep 0.01; done"
        ],
        overrides
      )

    write_workflow_file!(Workflow.workflow_file_path(), config)

    Application.put_env(:aiur, :memory_tracker_issues, issues)

    on_exit(fn ->
      File.touch(release_file)
      restore_application_env(:memory_tracker_issues, previous_issues)
    end)

    release_file
  end

  defp eventually?(fun, attempts \\ 100)

  defp eventually?(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually?(fun, attempts - 1)
    end
  end

  defp eventually?(_fun, 0), do: false
end
