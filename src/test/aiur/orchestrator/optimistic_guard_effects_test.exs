defmodule Aiur.Orchestrator.OptimisticGuardEffectsTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.{Attention, Store}
  alias Aiur.{Config, Issue, TrackerIdentity}
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.{OptimisticGuardEffects, OptimisticLedger, OptimisticSlots, PauseResume, Slots, State, TrackerTasks}

  defmodule MissingConditionalRead do
  end

  @topic "ticket.11.queue.attention.optimistic_blocker_failed"
  @park {:park, "11", "10", :pr_closed_unmerged}

  setup do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, OptimisticLedger)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, OptimisticLedger) end)
    root = Aiur.TestSupport.tmp_root!("optimistic-guard-effects")
    path = Path.join(root, "starts.json")
    previous = Application.fetch_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, root)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :decision_state_dir, value)
        :error -> Application.delete_env(:aiur, :decision_state_dir)
      end

      Aiur.TestCleanup.rm_rf!(root)
    end)

    start_ledger(path)

    assert :ok =
             OptimisticLedger.record_start("11", %{
               attempt_id: "guard-effects",
               start_trigger: :pr_opened,
               started_at_ms: 100,
               blockers: [%{"id" => "10", "pr_number" => 77, "pr_state" => "open", "pr_head_ref_at_start" => "refs/heads/aiur/10-blocker", "pr_head_sha_at_start" => "original"}]
             })

    :ok = Exchange.subscribe(@topic <> ".#")
    {:ok, path: path, opts: effect_options()}
  end

  test "restart between pause and label resumes the park without repeating pause or comment", %{path: path, opts: opts} do
    failed_label = fn "11", "agent:parked" -> {:error, :offline} end
    state = OptimisticGuardEffects.execute(running(), @park, Keyword.put(opts, :label, failed_label))
    assert_received {:effect, :pause}
    assert blocker()["pause_complete"] == true
    assert blocker()["label_complete"] != true
    refute_received {:effect, :comment}
    refute_received {:event, %{topic: @topic}}

    stop_supervised!(OptimisticLedger)
    start_ledger(path)
    state = OptimisticGuardEffects.execute(state, @park, opts)
    assert_received {:effect, :label}
    assert_received {:effect, :draft}
    assert_received {:effect, :comment}
    assert_received {:event, %{topic: @topic, blocker: "10", cause: :pr_closed_unmerged, action: :paused_parked}}
    refute_received {:effect, :pause}
    assert_complete()

    OptimisticGuardEffects.execute(state, @park, opts)
    refute_received {:effect, :pause}
    refute_received {:effect, :label}
    refute_received {:effect, :draft}
    refute_received {:effect, :comment}
    refute_received {:event, %{topic: @topic}}
    assert {:ok, %{latches: [latch]}} = Store.load()
    assert latch.key == {:optimistic_blocker_failed, "11"}
    assert latch.emitted?
  end

  test "open ledger and unsupported tracker closure cannot crash or park", %{opts: opts} do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    previous = Application.fetch_env(:aiur, :github_client_module)
    Application.put_env(:aiur, :github_client_module, MissingConditionalRead)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :github_client_module, value)
        :error -> Application.delete_env(:aiur, :github_client_module)
      end
    end)

    opts = Keyword.merge(opts, settings: Config.settings!(), fetch_issues: fn _ -> {:ok, [remote_issue("10", [])]} end, blocked_by: fn _ -> {:ok, ["10"]} end)
    state = running()
    assert OptimisticGuardEffects.reconcile(state, opts) == state
    assert {:ok, %{"status" => "running"}} = OptimisticLedger.get("11")
    refute_received {:effect, :pause}
    refute_received {:effect, :label}
    refute_received {:effect, :draft}
    refute_received {:event, %{topic: @topic}}
  end

  test "default park label uses the transition owner and records its writer", %{opts: opts} do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")
    previous = Application.fetch_env(:aiur, :memory_tracker_recipient)
    Application.put_env(:aiur, :memory_tracker_recipient, self())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :memory_tracker_recipient, value)
        :error -> Application.delete_env(:aiur, :memory_tracker_recipient)
      end
    end)

    handler = "optimistic-park-writer-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:aiur, :ticket_transition], fn _, _, meta, pid -> send(pid, {:transition, meta}) end, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    OptimisticGuardEffects.execute(running(), @park, Keyword.delete(opts, :label))
    assert_received {:memory_tracker_add_label, "11", "agent:parked"}
    assert_received {:transition, %{issue_id: "11", action: :add, to: "agent:parked", writer: :optimistic_guard, outcome: :ok}}
    assert_complete()
  end

  test "real pause control waits for worker evidence and retries a rejected request", %{opts: opts} do
    state = %{confirmed_running() | effective_concurrent_agents: 1}
    state = put_in(state.running["11"], Map.put(state.running["11"], :start_mode, :optimistic))
    assert Slots.available_slots(state) == 0
    assert OptimisticSlots.status(state).running == 1
    opts = Keyword.delete(opts, :pause)
    pending = OptimisticGuardEffects.execute(state, @park, opts)
    assert_receive {:pause_agent, first_id, 101}, 1_000
    assert pending.running["11"].control.status == :working
    assert blocker()["pause_complete"] != true
    assert blocker()["park_complete"] != true
    assert_received {:effect, :comment}
    assert_received {:event, %{topic: @topic, action: :paused_parked}}

    pending = OptimisticGuardEffects.execute(pending, @park, opts)
    refute_received {:pause_agent, _, _}
    refute_received {:effect, :comment}
    refute_received {:event, %{topic: @topic}}
    assert blocker()["pause_complete"] != true

    assert {:noreply, rejected} = PauseResume.handle_worker_control_rejected(pending, "11", first_id, 101, :control_failed)
    assert rejected.control_lifecycle.records[first_id].status == :rejected
    retried = OptimisticGuardEffects.execute(rejected, @park, opts)
    assert_receive {:pause_agent, second_id, 101}, 1_000
    assert second_id != first_id
    assert blocker()["pause_complete"] != true
    refute_received {:effect, :comment}
    refute_received {:event, %{topic: @topic}}

    assert {:noreply, applied} = PauseResume.handle_worker_control_state(retried, "11", :paused, %{request_id: second_id, generation: 101, kind: :optimistic_blocker_failed})
    assert applied.running["11"].control.status == :paused
    assert applied.running["11"].paused_reason == :optimistic_blocker_failed
    assert Slots.available_slots(applied) == 1
    assert OptimisticSlots.status(applied).running == 0
    assert applied.control_lifecycle.records[second_id].status == :applied
    OptimisticGuardEffects.execute(applied, @park, opts)
    assert_complete()
    refute_received {:pause_agent, _, _}
    refute_received {:effect, :comment}
    refute_received {:event, %{topic: @topic}}
  end

  test "global pause leaves pause pending and completes parking after resume", %{opts: opts} do
    state = %{running() | globally_paused: true}
    state = OptimisticGuardEffects.execute(state, @park, opts)
    refute_received {:effect, :pause}
    assert blocker()["pause_complete"] != true
    assert blocker()["park_complete"] != true
    assert_received {:effect, :label}
    assert_received {:effect, :draft}
    assert_received {:effect, :comment}
    assert_received {:event, %{topic: @topic, action: :paused_parked}}

    state = %{state | globally_paused: false}
    OptimisticGuardEffects.execute(state, @park, opts)
    assert_received {:effect, :pause}
    refute_received {:effect, :comment}
    refute_received {:event, %{topic: @topic}}
    assert_complete()
  end

  test "a finished dependent is parked with no pause and a parked action", %{opts: opts} do
    OptimisticGuardEffects.execute(%State{}, @park, opts)
    refute_received {:effect, :pause}
    assert_received {:effect, :label}
    assert_received {:effect, :draft}
    assert_received {:effect, :comment}
    assert_received {:event, %{topic: @topic, action: :parked}}
    assert_complete()
  end

  test "poll reconciliation reads a closed blocker and parks one tick beyond grace", %{opts: opts} do
    {:ok, clock} = Agent.start_link(fn -> 1_000 end)
    test_pid = self()

    opts =
      Keyword.merge(opts,
        settings: Config.settings!(),
        clock: fn -> Agent.get(clock, & &1) end,
        grace_ms: 10,
        observation_max_age_ms: 1,
        blocked_by: fn "11" -> {:ok, ["10"]} end,
        fetch_issues: fn ids ->
          {:ok, Enum.map(ids, &remote_issue(&1, ["agent:parked"]))}
        end,
        closure: fn "10", 1 -> {:ok, %{open?: true, state_reason: nil}} end,
        read_pr: fn "10", 77 ->
          send(test_pid, {:effect, :read_pr})
          {:ok, %{"number" => 77, "state" => "closed", "merged" => false, "head" => %{"ref" => "aiur/10-blocker", "sha" => "original"}}}
        end
      )

    issue = %Issue{id: "10", identifier: "10", state: "in-progress"}
    state = OptimisticGuardEffects.reconcile(%{running() | last_polled_issues: %{"10" => issue}}, opts)
    assert_received {:effect, :read_pr}
    refute_received {:effect, :pause}
    refute_received {:event, %{topic: @topic}}
    assert blocker()["suspect_since_ms"] == 1_000
    assert blocker()["guard_observation"]["pr_merged"] == false

    Agent.update(clock, fn _ -> 1_011 end)
    state = OptimisticGuardEffects.reconcile(state, opts)
    assert_received {:effect, :read_pr}
    assert_received {:effect, :pause}
    assert_received {:effect, :label}
    assert_received {:effect, :draft}
    assert_received {:effect, :comment}
    assert_received {:event, %{topic: @topic, action: :paused_parked}}
    assert_complete()

    OptimisticGuardEffects.reconcile(state, opts)
    refute_received {:effect, :pause}
    refute_received {:effect, :comment}
    refute_received {:event, %{topic: @topic}}
    Agent.stop(clock)
  end

  test "explicit unpark releases a completed park without immediately repeating the failure", %{opts: opts} do
    state = OptimisticGuardEffects.execute(running(), @park, opts)
    assert_complete()
    assert_received {:effect, :pause}
    assert_received {:effect, :label}
    assert_received {:effect, :draft}
    assert_received {:effect, :comment}
    assert_received {:event, %{topic: @topic}}

    opts = remote_options(opts, [])
    state = OptimisticGuardEffects.reconcile(state, opts)
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "running"
    assert row["counters"]["parks"] == 1
    assert row["counters"]["resumes_after_park"] == 1
    assert hd(row["blockers"])["failure_acknowledged"] == true
    assert hd(row["blockers"])["guard_observation"]["pr_state"] == "closed"
    assert {:ok, %{latches: []}} = Store.load()
    resolved = @topic <> ".resolved"
    assert_received {:event, %{topic: ^resolved}}
    refute_received {:event, %{topic: @topic}}
    refute_received {:effect, :pause}
    refute_received {:effect, :comment}

    OptimisticGuardEffects.reconcile(state, opts)
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "running"
    assert row["counters"]["resumes_after_park"] == 1
    refute_received {:event, %{topic: @topic}}
    refute_received {:effect, :pause}
    refute_received {:effect, :comment}
  end

  test "explicit unpark schedules attention cleanup outside the orchestrator", %{opts: opts} do
    state = OptimisticGuardEffects.execute(running(), @park, opts)
    assert_received {:event, %{topic: @topic}}
    owner = self()

    opts =
      remote_options(opts, [])
      |> Keyword.put(:attention, fn _, _, _ ->
        send(owner, {:cleanup_owner, self()})
        :ok
      end)

    state = OptimisticGuardEffects.reconcile(%{state | snapshot_key: owner}, opts)
    [ref] = Map.keys(state.tracker_tasks)
    assert_receive {^ref, observations}, 1_000
    assert {:handled, state} = TrackerTasks.result(state, ref, observations)
    assert [%{key: {:optimistic_attention, "11"}}] = Map.values(state.tracker_tasks)
    assert_receive {:cleanup_owner, task}, 1_000
    refute task == owner
    [cleanup_ref] = Map.keys(state.tracker_tasks)
    assert_receive {^cleanup_ref, :ok}, 1_000
    assert {:handled, _state} = TrackerTasks.result(state, cleanup_ref, :ok)
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "running"
  end

  test "closing a parked attempt clears its attention without remote reads", %{opts: opts} do
    state = OptimisticGuardEffects.execute(running(), @park, opts)
    assert_received {:event, %{topic: @topic}}
    assert {:ok, %{latches: [latch]}} = Store.load()
    assert latch.emitted?
    assert :ok = OptimisticLedger.close("11", :merged, 1_001)

    opts = remote_options(opts, ["agent:parked"])
    state = OptimisticGuardEffects.reconcile(state, opts)
    resolved = @topic <> ".resolved"
    assert_received {:event, %{topic: ^resolved}}
    assert {:ok, %{latches: []}} = Store.load()
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "closed"
    assert row["guard_attention_open"] == false
    refute_received {:remote_read, _}
    OptimisticGuardEffects.reconcile(state, opts)
    refute_received {:event, %{topic: ^resolved}}
    refute_received {:remote_read, _}
  end

  test "queue-disabled fallback emits once across restart and resolves on closure", %{path: path, opts: opts} do
    opts = Keyword.put(opts, :attention, fn _action, _dep, _payload -> {:error, :disabled} end)
    state = OptimisticGuardEffects.execute(running(), @park, opts)
    assert_complete()
    assert_received {:effect, :pause}
    assert_received {:effect, :label}
    assert_received {:effect, :draft}
    assert_received {:effect, :comment}
    assert_received {:event, %{topic: @topic, blocker: "10", cause: :pr_closed_unmerged, action: :paused_parked}}
    assert blocker()["attention_emitted"] == true
    assert {:ok, %{latches: []}} = Store.load()

    OptimisticGuardEffects.execute(state, @park, opts)
    stop_supervised!(OptimisticLedger)
    start_ledger(path)
    OptimisticGuardEffects.execute(state, @park, opts)
    refute_received {:event, %{topic: @topic}}
    refute_received {:effect, :pause}
    refute_received {:effect, :comment}
    assert :ok = OptimisticLedger.close("11", :discarded, 1_001)

    opts = remote_options(opts, ["agent:parked"])
    state = OptimisticGuardEffects.reconcile(state, opts)
    resolved = @topic <> ".resolved"
    assert_received {:event, %{topic: ^resolved}}
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["guard_attention_open"] == false
    assert {:ok, %{latches: []}} = Store.load()
    OptimisticGuardEffects.reconcile(state, opts)
    refute_received {:event, %{topic: ^resolved}}
    refute_received {:remote_read, _}
  end

  defp remote_options(opts, dependent_labels) do
    test_pid = self()

    Keyword.merge(opts,
      settings: Config.settings!(),
      grace_ms: 0,
      blocked_by: fn "11" ->
        send(test_pid, {:remote_read, :blocked_by})
        {:ok, ["10"]}
      end,
      fetch_issues: fn ids ->
        send(test_pid, {:remote_read, :issues})
        {:ok, Enum.map(ids, &remote_issue(&1, dependent_labels))}
      end,
      closure: fn "10", _max_age ->
        send(test_pid, {:remote_read, :closure})
        {:ok, %{open?: true, state_reason: nil}}
      end,
      read_pr: fn "10", 77 ->
        send(test_pid, {:remote_read, :pr})
        {:ok, %{"number" => 77, "state" => "closed", "merged" => false, "head" => %{"ref" => "aiur/10-blocker", "sha" => "original"}}}
      end
    )
  end

  defp remote_issue("11", labels), do: %Issue{id: "11", identifier: "11", state: "in-progress", labels: labels}
  defp remote_issue(id, _labels), do: %Issue{id: id, identifier: id, state: "in-progress"}

  defp start_ledger(path), do: start_supervised!({OptimisticLedger, [path: path]})

  test "failed observation tasks retain work and report the affected dependent", %{opts: opts} do
    state = running()
    opts = Keyword.merge(opts, settings: Config.settings!(), observe: fn _, _, _ -> {:error, :offline} end)
    log = ExUnit.CaptureLog.capture_log(fn -> assert OptimisticGuardEffects.reconcile(state, opts) == state end)
    assert log =~ "ticket=11"
    assert log =~ "offline"
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "running"
    refute_received {:effect, :pause}
    refute_received {:effect, :label}
  end

  defp running do
    issue = %Issue{id: "11", identifier: "11", state: "in-progress"}
    %State{running: %{"11" => %{identifier: "11", issue: issue, control: %{status: :working}}}}
  end

  defp confirmed_running do
    state = running()
    identity = %TrackerIdentity{version: 1, status: :joinable, kind: :github, owner: "owner", repository: "repo", provider_id: "I_11", identifier: "11", reason: nil}
    entry = state.running["11"]

    entry = %{
      entry
      | issue: %{entry.issue | tracker_identity: identity, selected_backend: "claude"},
        control: %{status: :working, can_interrupt: true, safe_checkpoints: [:notification], application_confirmation: :confirmed, generation: 101, version: 0}
    }

    entry = Map.merge(entry, %{pid: self(), ref: make_ref(), started_at: DateTime.utc_now(), session_id: "thread-11"})
    %{state | running: %{"11" => entry}}
  end

  defp effect_options do
    test_pid = self()

    [
      ledger: OptimisticLedger,
      label_prefix: "agent",
      clock: fn -> 1_000 end,
      pause: fn state, %{identifier: "11"} ->
        send(test_pid, {:effect, :pause})
        entry = put_in(state.running["11"], [:control, :status], :paused)
        {{:ok, 1}, %{state | running: Map.put(state.running, "11", entry)}}
      end,
      label: fn "11", "agent:parked" ->
        send(test_pid, {:effect, :label})
        :ok
      end,
      draft: fn "11" ->
        send(test_pid, {:effect, :draft})
        :ok
      end,
      comment: fn "11", "10", cause when cause in [:pr_closed_unmerged, "pr_closed_unmerged"] ->
        send(test_pid, {:effect, :comment})
        :ok
      end,
      attention: fn
        :open, dep, payload -> Attention.open(:optimistic_blocker_failed, dep, payload)
        :resolve, dep, _payload -> Attention.resolve(:optimistic_blocker_failed, dep)
      end
    ]
  end

  defp blocker do
    assert {:ok, row} = OptimisticLedger.get("11")
    hd(row["blockers"])
  end

  defp assert_complete do
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "parked"
    assert row["counters"]["parks"] == 1
    facts = hd(row["blockers"])
    assert facts["pause_complete"] == true
    assert facts["label_complete"] == true
    assert facts["draft_complete"] == true
    assert facts["comment_complete"] == true
    assert facts["park_complete"] == true
  end
end
