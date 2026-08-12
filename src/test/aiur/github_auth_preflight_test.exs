defmodule Aiur.GitHubAuthPreflightTest do
  use Aiur.TestSupport

  alias Aiur.{AlertFeed, Config.Paths, Issue}
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.GitHub.Client
  alias Aiur.GitHub.RequestContext
  alias Aiur.Orchestrator.{Dispatcher, PollContext, SnapshotPublisher, State, StatusReport}

  defmodule FailingPreflightClient do
    def preflight_auth do
      {:error,
       {:github_auth_preflight_failed,
        %{
          reason: :invalid_or_expired_token,
          endpoint: :issues,
          repo: "owner/repo",
          token_source: "GITHUB_TOKEN",
          status: 401,
          gh_keyring_status: :available,
          message: "GitHub auth preflight failed for GITHUB_TOKEN while validating owner/repo issues access. Aiur uses GITHUB_TOKEN and it takes precedence over `gh` keyring auth."
        }}}
    end

    def fetch_candidate_issues do
      if pid = Application.get_env(:aiur, :github_auth_preflight_test_pid) do
        send(pid, :candidate_fetch_called)
      end

      {:ok, []}
    end
  end

  defmodule HangingPreflightClient do
    def fetch_candidate_issues, do: {:ok, []}

    def preflight_auth do
      test_pid = Application.fetch_env!(:aiur, :github_auth_preflight_test_pid)
      send(test_pid, {:github_read_started, self(), RequestContext.timeout_ms(30_000)})

      receive do
        :release_github_read -> {:error, :deliberately_unavailable}
      end
    end
  end

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    Application.put_env(:aiur, :github_client_module, FailingPreflightClient)
    Application.put_env(:aiur, :github_auth_preflight_test_pid, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    on_exit(fn ->
      Application.delete_env(:aiur, :github_client_module)
      Application.delete_env(:aiur, :github_auth_preflight_test_pid)
      restore_env("GITHUB_TOKEN", prev_token)
    end)

    :ok
  end

  test "orchestrator stops before candidate polling when GitHub auth preflight fails" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.tracker.auth_preflight_failed")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    orchestrator_name = Module.concat(__MODULE__, :PreflightOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)
        wait_for_poll_completion(pid)
      end)

    assert log =~ "GitHub auth preflight failed for GITHUB_TOKEN"
    assert log =~ "takes precedence over `gh` keyring auth"
    refute log =~ "test-gh-token"
    refute_received :candidate_fetch_called

    assert_receive {:event, %{topic: "system.tracker.auth_preflight_failed"} = event}, 500
    assert event["reason"] =~ "GitHub tracker authentication preflight failed"
    assert event["reason"] =~ "classification=invalid_or_expired_token"
    assert event["needs_attention"] == true
  end

  test "orchestrator serves control reads while a GitHub read is hung off-process" do
    Application.put_env(:aiur, :github_client_module, HangingPreflightClient)
    write_workflow_file_synced!(Workflow.workflow_file_path(), tracker_kind: "memory")

    orchestrator_name = Module.concat(__MODULE__, :HungReadOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    Process.unlink(pid)

    write_workflow_file_synced!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    send(pid, :run_poll_cycle)
    assert_receive {:github_read_started, github_reader, 3_000}, 500

    on_exit(fn ->
      send(github_reader, :release_github_read)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    for number <- 1..100 do
      send(pid, {:worker_runtime_info, "missing-#{number}", %{worker_host: "test"}})
    end

    started_at = System.monotonic_time(:millisecond)
    assert [] == Orchestrator.status(orchestrator_name, 250)
    assert %{running: []} = Orchestrator.snapshot(orchestrator_name, 250)
    assert System.monotonic_time(:millisecond) - started_at < 250
    assert github_reader != pid
    assert {:message_queue_len, queued} = Process.info(pid, :message_queue_len)
    assert queued < 10

    send(github_reader, :release_github_read)

    assert Enum.any?(1..50, fn _attempt ->
             if Orchestrator.poll_status(orchestrator_name, 250).checking? do
               Process.sleep(10)
               false
             else
               true
             end
           end)

    completed_state = :sys.get_state(pid)
    assert completed_state.poll_task_token == nil
    assert :queue.is_empty(completed_state.poll_deferred)
  end

  test "catastrophic poll timeout stops the orchestrator and its poll task" do
    write_workflow_file_synced!(Workflow.workflow_file_path(), tracker_kind: "memory")
    orchestrator_name = Module.concat(__MODULE__, :TimedOutPollOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    Process.unlink(pid)
    test_pid = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :sys.replace_state(pid, &%{&1 | snapshot_ready?: true})
    initial_state = :sys.get_state(pid)
    :ok = StatusReport.notify_dashboard(initial_state)

    assert [{^orchestrator_name, _generation, initial_version, _snapshot_input}] =
             :ets.lookup(SnapshotPublisher, orchestrator_name)

    :sys.replace_state(pid, fn state ->
      {:noreply, next} =
        Dispatcher.start_poll_cycle(
          state,
          fn stale ->
            send(test_pid, {:timed_poll_started, self()})
            StatusReport.notify_dashboard(%{stale | snapshot_ready?: true})
            receive do: (:never -> stale)
          end,
          25
        )

      next
    end)

    assert_receive {:timed_poll_started, poll_pid}, 500
    monitor_ref = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, {:poll_cycle_timeout, _token}}, 500
    refute Process.alive?(poll_pid)

    assert [{^orchestrator_name, _generation, ^initial_version, _snapshot_input}] =
             :ets.lookup(SnapshotPublisher, orchestrator_name)
  end

  test "a delivered watchdog cannot replace an accepted poll result during replay" do
    write_workflow_file_synced!(Workflow.workflow_file_path(), tracker_kind: "memory")
    orchestrator_name = Module.concat(__MODULE__, :ResultWatchdogRaceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    Process.unlink(pid)
    test_pid = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :sys.replace_state(pid, fn state ->
      {:noreply, next} =
        Dispatcher.start_poll_cycle(
          state,
          fn current ->
            send(test_pid, {:race_poll_started, self()})
            receive do: (:release_race_poll -> current)
          end,
          1_000
        )

      next
    end)

    assert_receive {:race_poll_started, poll_pid}, 500

    for number <- 1..101 do
      send(pid, {:worker_runtime_info, "missing-#{number}", %{worker_host: "test"}})
    end

    assert [] == Orchestrator.status(orchestrator_name, 250)
    owner_state = :sys.get_state(pid)
    token = owner_state.poll_task_token
    accepted = %{owner_state | session_max_concurrent_agents: 9}

    send(pid, {:poll_cycle_result, token, accepted})
    send(pid, {:poll_cycle_timeout, token})

    wait_for_poll_completion(pid)
    assert Process.alive?(pid)
    assert :sys.get_state(pid).session_max_concurrent_agents == 9

    send(poll_pid, :release_race_poll)
  end

  test "state-changing calls replay in order after the poll result" do
    write_workflow_file_synced!(Workflow.workflow_file_path(), tracker_kind: "memory")
    orchestrator_name = Module.concat(__MODULE__, :DeferredCallOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    Process.unlink(pid)
    test_pid = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :sys.replace_state(pid, fn state ->
      {:noreply, next} =
        Dispatcher.start_poll_cycle(
          state,
          fn stale ->
            send(test_pid, {:deferred_poll_started, self()})

            receive do
              :finish_poll -> stale
            end
          end,
          1_000
        )

      next
    end)

    assert_receive {:deferred_poll_started, poll_pid}, 500
    mutation = Task.async(fn -> Orchestrator.set_max_concurrent_agents(orchestrator_name, 7) end)
    assert Task.yield(mutation, 25) == nil
    assert [] == Orchestrator.status(orchestrator_name, 250)

    send(poll_pid, :finish_poll)
    assert {:ok, %{max: 7}} = Task.await(mutation, 500)
    assert :sys.get_state(pid).session_max_concurrent_agents == 7
  end

  test "poll-dispatched worker monitors remain owned by the orchestrator" do
    write_workflow_file_synced!(Workflow.workflow_file_path(), tracker_kind: "memory")
    orchestrator_name = Module.concat(__MODULE__, :PollMonitorOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    Process.unlink(pid)
    test_pid = self()
    worker = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      send(worker, :stop)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :sys.replace_state(pid, fn state ->
      {:noreply, next} =
        Dispatcher.start_poll_cycle(
          state,
          fn current ->
            ref = PollContext.monitor(worker)
            send(test_pid, {:worker_monitor_created, self(), ref})
            current
          end,
          1_000
        )

      next
    end)

    assert_receive {:worker_monitor_created, poll_pid, monitor_ref}, 500
    assert poll_pid != pid
    wait_for_poll_completion(pid)

    assert {:monitors, monitors} = Process.info(pid, :monitors)
    assert {:process, worker} in monitors
    refute {:process, worker} in elem(Process.info(poll_pid, :monitors) || {:monitors, []}, 1)
    assert is_reference(monitor_ref)
  end

  test "tracker auth fleet alert is deduplicated by stable cause and rearms after recovery" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.tracker.auth_preflight_failed")
    :ok = Exchange.subscribe("system.tracker.auth_preflight_failed.resolved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    {:error, {:github_auth_preflight_failed, diagnostic}} = FailingPreflightClient.preflight_auth()

    changed_diagnostic = Map.put(diagnostic, :message, "latest probe failed at a different endpoint")

    {:ok, results} =
      Agent.start_link(fn ->
        [
          {:error, {:github_auth_preflight_failed, diagnostic}},
          {:error, {:github_auth_preflight_failed, changed_diagnostic}},
          :ok,
          {:error, {:github_auth_preflight_failed, changed_diagnostic}}
        ]
      end)

    preflight_fun = scripted_preflight(results)

    first = Dispatcher.maybe_dispatch(%State{}, & &1, preflight_fun)
    assert first.tracker_preflight_alert_signature == "github-auth:invalid_or_expired_token:owner/repo"

    assert_receive {:event, %{topic: "system.tracker.auth_preflight_failed"} = first_event}, 500
    assert first_event["reason"] =~ "fleet dispatch is paused"
    assert first_event["reason"] =~ "expected to clear automatically"

    same_outage = Dispatcher.maybe_dispatch(first, & &1, preflight_fun)
    assert same_outage.tracker_preflight_alert_signature == first.tracker_preflight_alert_signature
    refute_receive {:event, %{topic: "system.tracker.auth_preflight_failed"}}, 100

    # The same orchestrator must clear both the attention and its dashboard
    # hold as soon as the preflight succeeds.
    recovered = Dispatcher.maybe_dispatch(same_outage, & &1, preflight_fun)
    assert recovered.tracker_preflight_alert_signature == nil
    assert recovered.tracker_preflight_alert_resolution_emitted
    assert recovered.dispatch_hold == nil

    assert_receive {:event, %{topic: "system.tracker.auth_preflight_failed.resolved"}}, 500

    refute Enum.any?(AlertFeed.list(log_roots: [Paths.log_root_dir()], needs_attention: true), fn alert ->
             alert["topic"] == "system.tracker.auth_preflight_failed"
           end)

    rearmed = Dispatcher.maybe_dispatch(recovered, & &1, preflight_fun)
    assert rearmed.tracker_preflight_alert_signature == first.tracker_preflight_alert_signature

    assert_receive {:event, %{topic: "system.tracker.auth_preflight_failed"} = second_event}, 500
    assert second_event["reason"] =~ "latest probe failed at a different endpoint"

    assert Enum.any?(AlertFeed.list(log_roots: [Paths.log_root_dir()], needs_attention: true), fn alert ->
             alert["topic"] == "system.tracker.auth_preflight_failed"
           end)
  end

  test "free cached demand reports the tracker preflight reason instead of looking dispatchable" do
    Publisher.set_tracked_fn(fn _ -> true end)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
    end)

    issue = %Issue{
      id: "1580",
      identifier: "owner/repo#1580",
      state: "todo",
      title: "Eligible cached ticket"
    }

    state = %State{
      session_max_concurrent_agents: 4,
      effective_concurrent_agents: 4,
      last_polled_issues: %{issue.id => issue}
    }

    {:error, reason} = FailingPreflightClient.preflight_auth()
    held = Dispatcher.maybe_dispatch(state, & &1, fn current -> {:error, reason, current} end)
    snapshot = held |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()

    assert snapshot.capacity.available == 4
    assert snapshot.capacity.queued_demand?
    assert snapshot.capacity_hold.held? == false

    assert %{
             held?: true,
             reason: :tracker_preflight,
             detail: :invalid_or_expired_token
           } = snapshot.dispatch_hold

    assert [%{identifier: "owner/repo#1580", waiting_reason: :tracker_unavailable}] = snapshot.idle
  end

  test "missing GitHub token emits a fleet auth alert before polling" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.tracker.auth_preflight_failed")

    {:ok, results} = Agent.start_link(fn -> [{:error, :missing_github_token}] end)
    preflight_fun = scripted_preflight(results)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    state = Dispatcher.maybe_dispatch(%State{}, & &1, preflight_fun)
    assert state.tracker_preflight_alert_signature == "github-auth:missing_github_token"

    assert_receive {:event, %{topic: "system.tracker.auth_preflight_failed"} = event}, 500
    assert event["reason"] =~ "missing_github_token"
  end

  test "preflight formatter handles plain reasons for logging fallback" do
    assert Client.format_auth_preflight_error(:missing_github_token) == ":missing_github_token"
  end

  defp scripted_preflight(results) do
    &next_preflight_result(results, &1)
  end

  defp next_preflight_result(results, state) do
    Agent.get_and_update(results, &pop_preflight_result(&1, state))
  end

  defp pop_preflight_result([:ok | rest], state), do: {{:ok, state}, rest}

  defp pop_preflight_result([{:error, reason} | rest], state),
    do: {{:error, reason, state}, rest}

  defp wait_for_poll_completion(pid, attempts \\ 100)

  defp wait_for_poll_completion(_pid, 0), do: flunk("poll cycle did not complete")

  defp wait_for_poll_completion(pid, attempts) do
    state = :sys.get_state(pid)

    if is_nil(state.poll_task_token) and is_integer(state.next_poll_due_at_ms) do
      :ok
    else
      Process.sleep(10)
      wait_for_poll_completion(pid, attempts - 1)
    end
  end
end
