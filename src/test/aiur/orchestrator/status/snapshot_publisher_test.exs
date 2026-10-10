defmodule Aiur.Orchestrator.Status.SnapshotPublisherTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport

  alias Aiur.Orchestrator.SnapshotPublisher
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport

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

  test "an orchestrator wedged after draining its mailbox still reports a stale fleet snapshot" do
    orchestrator_name = Module.concat(__MODULE__, :DrainedWedgeSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    previous_ceiling = Application.get_env(:aiur, :snapshot_stale_age_ceiling_ms)
    Application.put_env(:aiur, :snapshot_stale_age_ceiling_ms, 60)

    on_exit(fn ->
      if is_nil(previous_ceiling) do
        Application.delete_env(:aiur, :snapshot_stale_age_ceiling_ms)
      else
        Application.put_env(:aiur, :snapshot_stale_age_ceiling_ms, previous_ceiling)
      end

      try do
        :sys.resume(pid)
      catch
        :exit, _reason -> :ok
      end

      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :ok = SnapshotStore.publish(orchestrator_name, %{running: [], retrying: [], idle: []})

    # The symmetric failure to a backlogged orchestrator: this one wedges with
    # an empty mailbox, so no backlog corroborates the stall; a depth-gated rule
    # would serve it as `:current` forever. Age alone must be enough. Drain the
    # init startup-cleanup task first, or its reply and :DOWN fill the mailbox.
    assert eventually?(fn -> :sys.get_state(pid).tracker_tasks == %{} end)
    :sys.suspend(pid)
    Process.sleep(90)

    assert 0 = pid |> Process.info(:message_queue_len) |> elem(1)

    assert {:stale, %{running: [], retrying: [], idle: []}, %{status: :stale, reason: :snapshot_stalled, age_seconds: age_seconds}} =
             Orchestrator.dashboard_snapshot(orchestrator_name, 5_000)

    assert is_integer(age_seconds)

    # A long read timeout must not buy back currency: the ceiling is absolute.
    assert {:stale, _snapshot, %{reason: :snapshot_stalled}} =
             Orchestrator.dashboard_snapshot(orchestrator_name, 600_000)
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
    assert :orchestrator_unavailable = SnapshotStore.read(orchestrator, 50)
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
end
