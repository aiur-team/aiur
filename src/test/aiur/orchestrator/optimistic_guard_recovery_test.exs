defmodule Aiur.Orchestrator.OptimisticGuardRecoveryTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.Attention
  alias Aiur.Events.Exchange
  alias Aiur.Issue
  alias Aiur.Orchestrator.{OptimisticGuardEffects, OptimisticLedger, State, TrackerTasks}

  @topic "ticket.11.queue.attention.optimistic_blocker_failed"
  @park {:park, "11", "10", :pr_closed_unmerged}

  setup do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, OptimisticLedger)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, OptimisticLedger) end)
    root = Aiur.TestSupport.tmp_root!("optimistic-guard-recovery")
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

    start_supervised!({OptimisticLedger, [path: path]})

    assert :ok =
             OptimisticLedger.record_start("11", %{
               attempt_id: "guard-recovery",
               start_trigger: :pr_opened,
               started_at_ms: 100,
               blockers: [%{"id" => "10", "pr_number" => 77, "pr_state" => "open", "pr_head_ref_at_start" => "refs/heads/aiur/10-blocker", "pr_head_sha_at_start" => "original"}]
             })

    :ok = Exchange.subscribe(@topic <> ".#")

    {:ok,
     opts: [
       ledger: OptimisticLedger,
       label_prefix: "agent",
       clock: fn -> 1_000 end,
       attention: &attention/3,
       label: fn _, _ -> :ok end,
       draft: fn _ -> :ok end,
       comment: fn _, _, _ -> :ok end
     ]}
  end

  test "recovery resumes a live optimistic pause and does tracker writes off the owner", %{opts: opts} do
    entry = %{identifier: "11", issue: issue("11", "in-progress", []), paused_reason: :optimistic_blocker_failed, control: %{status: :paused}}
    state = OptimisticGuardEffects.execute(%State{running: %{"11" => entry}}, @park, opts)
    assert parked_attempt?()
    owner = self()

    opts =
      opts
      |> Keyword.put(:observe, recovered_observation("11", ["agent:parked", "agent:in-progress", "agent:queued"]))
      |> Keyword.put(:update_state_fun, fn id, target, expected ->
        send(owner, {:recovery_state, self(), id, target, expected})
        :ok
      end)
      |> Keyword.put(:remove_marker_fun, fn id, marker ->
        send(owner, {:recovery_marker, self(), id, marker})
        :ok
      end)
      |> Keyword.put(:resume_paused_fun, fn current, paused_entry ->
        send(owner, {:resume_paused, paused_entry.paused_reason, paused_entry.issue.state, paused_entry.issue.parked})
        {{:ok, :resumed}, %{current | running: Map.put(current.running, "11", %{paused_entry | control: %{status: :working}})}}
      end)

    state = OptimisticGuardEffects.reconcile(%{state | snapshot_key: owner}, opts)
    [ref] = Map.keys(state.tracker_tasks)
    assert_receive {^ref, observations}, 1_000
    assert {:handled, state} = TrackerTasks.result(state, ref, observations)
    [recovery_ref] = Map.keys(state.tracker_tasks)
    assert_receive {^recovery_ref, :ok}, 1_000
    assert {:handled, state} = TrackerTasks.result(state, recovery_ref, :ok)
    [finish_ref] = Map.keys(state.tracker_tasks)
    assert_receive {^finish_ref, :ok}, 1_000
    assert {:handled, state} = TrackerTasks.result(state, finish_ref, :ok)
    assert_receive {:recovery_state, task, "11", "in-progress", "in-progress"}, 1_000
    refute task == owner
    assert_receive {:recovery_marker, ^task, "11", "agent:parked"}, 1_000
    assert_received {:resume_paused, :optimistic_blocker_failed, "in-progress", false}
    assert state.running["11"].control.status == :working
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "running"
    assert row["counters"]["resumes_after_park"] == 1
  end

  test "a newer operator hold prevents optimistic recovery", %{opts: opts} do
    state = parked_attempt(opts)

    opts =
      Keyword.put(opts, :observe, recovered_observation("11", ["agent:parked", "agent:in-progress", "needs-triage", "worker:paused"]))
      |> Keyword.put(:update_state_fun, fn _, _, _ -> flunk("operator-held state must not be rewritten") end)

    OptimisticGuardEffects.reconcile(state, opts)
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "parked"
    assert row["counters"]["resumes_after_park"] == 0
    refute_received {:event, %{topic: "#{@topic}.resolved"}}
  end

  test "unrecovered blockers and failed state writes keep the park and alert", %{opts: opts} do
    state = parked_attempt(opts)
    owner = self()
    state = %{state | snapshot_key: owner}
    open = %{confirmed?: true, observed_at_ms: 1_000, issue_open?: true, pr_merged: false, pr_state: "open", any_open_pr?: true}
    unrecovered = fn _, now, _ -> %{"10" => %{open | observed_at_ms: now}, dependents: %{"11" => issue("11", "in-progress", ["agent:parked", "agent:in-progress"])}} end
    no_write = Keyword.put(opts, :observe, unrecovered) |> Keyword.put(:update_state_fun, fn _, _, _ -> flunk("open blockers must not be released") end)
    state = OptimisticGuardEffects.reconcile(state, no_write)
    [observe_ref] = Map.keys(state.tracker_tasks)
    assert_receive {^observe_ref, observations}, 1_000
    assert {:handled, state} = TrackerTasks.result(state, observe_ref, observations)
    assert state.tracker_tasks == %{}
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "parked"
    assert row["counters"]["resumes_after_park"] == 0

    failing_write =
      Keyword.put(opts, :observe, recovered_observation("11", ["agent:parked", "agent:in-progress"]))
      |> Keyword.put(:update_state_fun, fn _, _, _ ->
        send(owner, {:state_write_owner, self()})
        {:error, :offline}
      end)

    state = OptimisticGuardEffects.reconcile(state, failing_write)
    [observe_ref] = Map.keys(state.tracker_tasks)
    assert_receive {^observe_ref, observations}, 1_000
    assert {:handled, state} = TrackerTasks.result(state, observe_ref, observations)
    [recovery_ref] = Map.keys(state.tracker_tasks)
    assert_receive {^recovery_ref, {:error, :offline}}, 1_000
    assert {:handled, state} = TrackerTasks.result(state, recovery_ref, {:error, :offline})
    assert_receive {:state_write_owner, writer}, 1_000
    refute writer == owner
    assert state.tracker_tasks == %{}
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "parked"
    assert row["guard_attention_open"]
    assert row["counters"]["resumes_after_park"] == 0
    refute_received {:event, %{topic: "#{@topic}.resolved"}}
  end

  test "recovery uses configured rework labels and accepts a missing current state", %{opts: opts} do
    opts = Keyword.put(opts, :label_prefix, "worker")
    state = parked_attempt(opts)
    observation = recovered_observation("11", ["worker:parked", "worker:rework"])

    observation = fn records, now, options ->
      Map.update!(observation.(records, now, options), :dependents, &Map.update!(&1, "11", fn remote -> %{remote | state: nil} end))
    end

    opts =
      Keyword.put(opts, :observe, observation)
      |> Keyword.put(:update_state_fun, fn id, target, expected ->
        send(self(), {:state_update, id, target, expected})
        :ok
      end)
      |> Keyword.put(:remove_marker_fun, fn id, marker ->
        send(self(), {:marker_remove, id, marker})
        :ok
      end)

    OptimisticGuardEffects.reconcile(state, opts)
    assert_received {:state_update, "11", "rework", :none}
    assert_received {:marker_remove, "11", "worker:parked"}
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "running"
  end

  defp parked_attempt(opts) do
    state = OptimisticGuardEffects.execute(%State{}, @park, opts)
    assert parked_attempt?()
    state
  end

  defp parked_attempt? do
    assert {:ok, row} = OptimisticLedger.get("11")
    row["status"] == "parked" and hd(row["blockers"])["park_complete"] == true
  end

  defp recovered_observation(id, labels) do
    fn _records, now, _opts ->
      %{
        "10" => %{confirmed?: true, observed_at_ms: now, issue_open?: false, state_reason: :completed, pr_merged: false},
        dependents: %{"11" => issue(id, "in-progress", labels)}
      }
    end
  end

  defp issue(id, state, labels), do: %Issue{id: id, identifier: id, state: state, labels: labels}

  defp attention(:open, dep, payload), do: Attention.open(:optimistic_blocker_failed, dep, payload)
  defp attention(:resolve, dep, _payload), do: Attention.resolve(:optimistic_blocker_failed, dep)
end
