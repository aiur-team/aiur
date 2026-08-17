defmodule Aiur.Orchestrator.GlobalPauseTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{GlobalPause, GlobalPauseStore, PauseResume, State}

  test "set_global_pause distinguishes a timeout from an unavailable server" do
    server = spawn(fn -> Process.sleep(:infinity) end)
    name = Module.concat(__MODULE__, :UnresponsiveOrchestrator)
    Process.register(server, name)
    on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :kill) end)

    assert {:error, :timeout} = GlobalPause.set_global_pause(name, true, "test", 1)
  end

  describe "GlobalPauseStore recovery" do
    test "distinguishes a missing store from an unreadable store" do
      path = Path.join(System.tmp_dir!(), "global-pause-missing-#{System.unique_integer([:positive])}.json")
      previous = Application.get_env(:aiur, :global_pause_store_path)
      Application.put_env(:aiur, :global_pause_store_path, path)

      on_exit(fn ->
        File.rm(path)

        if is_nil(previous),
          do: Application.delete_env(:aiur, :global_pause_store_path),
          else: Application.put_env(:aiur, :global_pause_store_path, previous)
      end)

      assert {:ok, %{globally_paused: false}} = GlobalPauseStore.load()

      File.write!(path, "not json")
      assert {:error, {:read_failed, _reason}} = GlobalPauseStore.load()
    end

    test "rejects a decoded store without a boolean pause flag" do
      path = Path.join(System.tmp_dir!(), "global-pause-invalid-#{System.unique_integer([:positive])}.json")
      previous = Application.get_env(:aiur, :global_pause_store_path)
      Application.put_env(:aiur, :global_pause_store_path, path)

      on_exit(fn ->
        File.rm(path)

        if is_nil(previous),
          do: Application.delete_env(:aiur, :global_pause_store_path),
          else: Application.put_env(:aiur, :global_pause_store_path, previous)
      end)

      File.write!(path, Jason.encode!(%{"globally_paused" => "yes"}))
      assert {:error, {:read_failed, {:invalid_field, "globally_paused"}}} = GlobalPauseStore.load()
    end

    test "keeps the store stable when the run log root changes" do
      state_dir = Path.join(System.tmp_dir!(), "global-pause-state-#{System.unique_integer([:positive])}")
      run_one_root = Path.join(System.tmp_dir!(), "global-pause-run-one-#{System.unique_integer([:positive])}")
      run_two_root = Path.join(System.tmp_dir!(), "global-pause-run-two-#{System.unique_integer([:positive])}")
      run_one_log = Path.join(run_one_root, "log/aiur.log")
      run_two_log = Path.join(run_two_root, "log/aiur.log")
      previous_store = Application.get_env(:aiur, :global_pause_store_path)
      previous_decision_dir = Application.get_env(:aiur, :decision_state_dir)
      previous_log_file = Application.get_env(:aiur, :log_file)

      Application.delete_env(:aiur, :global_pause_store_path)
      Application.put_env(:aiur, :decision_state_dir, state_dir)
      Application.put_env(:aiur, :log_file, run_one_log)

      on_exit(fn ->
        File.rm_rf(state_dir)
        File.rm_rf(run_one_root)
        File.rm_rf(run_two_root)
        restore_application_env(:global_pause_store_path, previous_store)
        restore_application_env(:decision_state_dir, previous_decision_dir)
        restore_application_env(:log_file, previous_log_file)
      end)

      first_path = GlobalPauseStore.path_for()
      assert first_path == Path.join(state_dir, "global-pause.json")
      assert :ok = GlobalPauseStore.save(%{globally_paused: true, paused_at: nil, source: "dashboard"})

      Application.put_env(:aiur, :log_file, run_two_log)

      assert GlobalPauseStore.path_for() == first_path
      assert {:ok, %{globally_paused: true, source: "dashboard"}} = GlobalPauseStore.load()
    end
  end

  describe "set_global_pause_call/2 pause" do
    test "holds every working agent and tags them global_pause without overriding an individual pause" do
      individual = unique_id("gp-individual")
      free = unique_id("gp-free")

      state =
        base_state(
          running: %{
            individual => running_entry(individual),
            free => running_entry(free)
          }
        )

      # An operator individually pauses one agent first.
      state = apply_pause(state, individual, :operator_pause)
      assert state.running[individual].control.status == :paused
      assert state.running[individual].paused_reason == :operator_pause

      # Global pause: the individually paused agent is skipped; the free one is held.
      {:reply, {:ok, %{globally_paused: true}}, paused_state} =
        GlobalPause.set_global_pause_call(state, true)

      assert paused_state.globally_paused
      # No new control request is routed to the already-paused agent.
      refute_receive {:pause_agent, _rid, _gen, _id_extra}, 50
      assert paused_state.running[individual].paused_reason == :operator_pause

      # The free agent received a global-pause hold request.
      assert %{reason: :global_pause} = paused_state.running[free].pending_pause_reason
      assert_receive {:pause_agent, free_rid, 101}

      applied_state = apply_worker_pause(paused_state, free, free_rid, :global_pause)
      assert applied_state.running[free].control.status == :paused
      assert applied_state.running[free].paused_reason == :global_pause
      # Individual pause is untouched throughout.
      assert applied_state.running[individual].paused_reason == :operator_pause
    end
  end

  describe "set_global_pause_call/2 unpause" do
    test "resumes only globally held agents and leaves individually paused agents paused" do
      individual = unique_id("gp-keep")
      held = unique_id("gp-held")

      state =
        base_state(
          globally_paused: true,
          running: %{
            individual => paused_entry(individual, :operator_pause),
            held => paused_entry(held, :global_pause)
          }
        )

      {:reply, {:ok, %{globally_paused: false}}, resumed_state} =
        GlobalPause.set_global_pause_call(state, false)

      refute resumed_state.globally_paused
      assert is_reference(resumed_state.tick_timer_ref)
      assert resumed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

      # Only the globally held agent gets a resume request.
      assert_receive {:resume_agent, held_rid, 101}
      refute_receive {:resume_agent, _rid, _gen}, 50

      # The individually paused agent is never touched.
      assert resumed_state.running[individual].control.status == :paused
      assert resumed_state.running[individual].paused_reason == :operator_pause

      # Applying the worker's resume evidence clears the global-pause marker.
      applied_state = apply_worker_resume(resumed_state, held, held_rid)
      refute Map.has_key?(applied_state.running[held], :paused_reason)
      assert applied_state.running[individual].paused_reason == :operator_pause
    end

    test "preserves a tracker pause added while an agent is globally held" do
      held = unique_id("gp-tracker-held")

      entry =
        held
        |> paused_entry(:global_pause)
        |> put_in([:issue, Access.key(:paused)], true)
        |> put_in([:issue, Access.key(:labels)], ["agent:in-progress", "agent:paused"])

      state = base_state(globally_paused: true, running: %{held => entry})

      {:reply, {:ok, %{globally_paused: false}}, resumed_state} =
        GlobalPause.set_global_pause_call(state, false)

      refute resumed_state.globally_paused
      assert resumed_state.running[held].control.status == :paused
      assert resumed_state.running[held].paused_reason == :label_override
      assert resumed_state.running[held].issue.paused
      refute_receive {:resume_agent, _request_id, _generation}, 50
    end
  end

  describe "global-hold-wins guard" do
    test "an individual resume is blocked while globally paused" do
      id = unique_id("gp-guard")
      state = base_state(globally_paused: true, running: %{id => paused_entry(id, :global_pause)})

      assert {:reply, {:error, :globally_paused}, ^state} =
               PauseResume.resume_issue_call(state, id)

      assert {:reply, {:error, :globally_paused}, ^state} =
               PauseResume.request_control_call(state, id, :resume, 7)

      refute_receive {:resume_agent, _rid, _gen}, 50
    end

    test "an individual pause is rejected while globally paused" do
      id = unique_id("gp-guard-pause")

      state =
        base_state(globally_paused: true, running: %{id => running_entry(id)})

      assert {:reply, {:error, :globally_paused}, ^state} =
               PauseResume.request_control_call(state, id, :pause, 8)

      refute_receive {:pause_agent, _rid, _gen}, 50
    end

    test "does not acknowledge a pause when persistence fails" do
      previous = Application.get_env(:aiur, :global_pause_store_path)
      Application.put_env(:aiur, :global_pause_store_path, "/dev/null/global-pause.json")

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:aiur, :global_pause_store_path),
          else: Application.put_env(:aiur, :global_pause_store_path, previous)
      end)

      id = unique_id("gp-persistence")
      state = base_state(running: %{id => running_entry(id)})

      assert {:reply, {:error, {:global_pause_persistence_failed, {:write_failed, _, _}}}, ^state} =
               GlobalPause.set_global_pause_call(state, true, "dashboard")

      refute_receive {:pause_agent, _rid, _gen}, 50
    end
  end

  describe "idempotency and projection" do
    test "re-pausing or re-unpausing is a no-op" do
      already_paused = base_state(globally_paused: true, running: %{})

      assert {:reply, {:ok, %{globally_paused: true} = _projection}, ^already_paused} =
               GlobalPause.set_global_pause_call(already_paused, true)

      already_running = base_state(globally_paused: false, running: %{})

      assert {:reply, {:ok, %{globally_paused: false} = _projection}, ^already_running} =
               GlobalPause.set_global_pause_call(already_running, false)
    end

    test "globally_paused_call and global_pause_status mirror the flag" do
      state = base_state(globally_paused: true, running: %{})

      assert {:reply, true, ^state} = GlobalPause.globally_paused_call(state)
      assert GlobalPause.global_pause_status(state) == %{globally_paused: true, paused_at: nil, source: nil}

      assert GlobalPause.global_pause_status(%{state | globally_paused: false}) ==
               %{globally_paused: false, paused_at: nil, source: nil}
    end

    test "persists the global pause and provenance across orchestrator restart" do
      path = Path.join(System.tmp_dir!(), "global-pause-#{System.unique_integer([:positive])}.json")
      previous = Application.get_env(:aiur, :global_pause_store_path)
      Application.put_env(:aiur, :global_pause_store_path, path)

      on_exit(fn ->
        File.rm(path)

        if is_nil(previous),
          do: Application.delete_env(:aiur, :global_pause_store_path),
          else: Application.put_env(:aiur, :global_pause_store_path, previous)
      end)

      name = Module.concat(__MODULE__, :RestoredOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
      assert {:ok, %{globally_paused: false}} = GlobalPause.global_pause_status(name)

      assert {:ok, %{globally_paused: true, paused_at: paused_at, source: "dashboard"}} =
               GlobalPause.set_global_pause(name, true, "dashboard")

      ref = Process.monitor(pid)
      Process.unlink(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      {:ok, restarted_pid} = Orchestrator.start_link(name: name, initial_poll?: false)

      on_exit(fn ->
        if Process.alive?(restarted_pid) do
          Process.unlink(restarted_pid)
          Process.exit(restarted_pid, :kill)
        end
      end)

      assert {:ok, %{globally_paused: true, paused_at: ^paused_at, source: "dashboard"}} =
               GlobalPause.global_pause_status(name)
    end

    test "holds the fleet when persisted pause recovery is corrupt" do
      path = Path.join(System.tmp_dir!(), "global-pause-corrupt-#{System.unique_integer([:positive])}.json")
      File.write!(path, "corrupt")
      previous = Application.get_env(:aiur, :global_pause_store_path)
      Application.put_env(:aiur, :global_pause_store_path, path)

      name = Module.concat(__MODULE__, :CorruptStoreOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
      Process.unlink(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        File.rm(path)

        if is_nil(previous),
          do: Application.delete_env(:aiur, :global_pause_store_path),
          else: Application.put_env(:aiur, :global_pause_store_path, previous)
      end)

      assert {:ok, %{globally_paused: true, source: "persistence recovery failed"}} =
               GlobalPause.global_pause_status(name)
    end

    test "does not report an unavailable orchestrator as unpaused" do
      name = Module.concat(__MODULE__, :MissingOrchestrator)

      assert {:error, :orchestrator_unavailable} = GlobalPause.globally_paused?(name)
      assert {:error, :orchestrator_unavailable} = GlobalPause.global_pause_status(name)
    end

    test "distinguishes a timed-out status query from an unavailable orchestrator" do
      name = Module.concat(__MODULE__, :SuspendedOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
      :sys.suspend(pid)

      try do
        assert {:error, :timeout} = GlobalPause.global_pause_status(name, 1)
      after
        :sys.resume(pid)
      end
    end
  end

  # Route a per-agent pause and apply the worker's confirming evidence.
  defp apply_pause(state, issue_id, reason) do
    {{:ok, _request_id}, pending} =
      PauseResume.request_pause(state, state.running[issue_id], state.running[issue_id].issue, reason)

    assert_receive {:pause_agent, request_id, 101}
    apply_worker_pause(pending, issue_id, request_id, reason)
  end

  defp apply_worker_pause(state, issue_id, request_id, kind) do
    {:noreply, applied} =
      Aiur.Orchestrator.handle_info(
        {:worker_control_state, issue_id, :paused, %{request_id: request_id, generation: 101, kind: kind}},
        state
      )

    applied
  end

  defp apply_worker_resume(state, issue_id, request_id) do
    {:noreply, applied} =
      Aiur.Orchestrator.handle_info(
        {:worker_control_state, issue_id, :working, %{request_id: request_id, generation: 101}},
        state
      )

    applied
  end

  defp paused_entry(issue_id, reason) do
    running_entry(issue_id,
      control: %{
        status: :paused,
        can_interrupt: true,
        safe_checkpoints: [:notification],
        application_confirmation: :confirmed,
        generation: 101,
        version: 1
      },
      paused_reason: reason
    )
  end

  defp base_state(attrs) do
    struct!(
      State,
      Keyword.merge(
        [
          running: %{},
          claimed: MapSet.new(),
          completed: MapSet.new(),
          retry_attempts: %{},
          max_concurrent_agents: 6,
          agent_totals: nil,
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
        ],
        attrs
      )
    )
  end

  defp running_entry(issue_id, attrs \\ []) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: issue_id,
      issue: %Issue{
        id: issue_id,
        identifier: issue_id,
        state: "in-progress",
        title: "Global pause switch",
        tracker_identity: tracker_identity(issue_id)
      },
      control: %{
        status: :working,
        can_interrupt: true,
        safe_checkpoints: [:notification],
        application_confirmation: :confirmed,
        generation: 101,
        version: 0
      },
      session_id: "thread-#{issue_id}",
      started_at: DateTime.utc_now()
    }
    |> Map.merge(Map.new(attrs))
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "I_kwDO#{identifier}",
      identifier: "101",
      reason: nil
    }
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)
end
