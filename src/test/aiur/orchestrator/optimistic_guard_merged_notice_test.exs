defmodule Aiur.Orchestrator.OptimisticGuardMergedNoticeTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.Attention
  alias Aiur.Orchestrator.{OptimisticGuardEffects, OptimisticLedger, State}

  setup do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, OptimisticLedger)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, OptimisticLedger) end)
    root = Aiur.TestSupport.tmp_root!("optimistic-merged-notice")
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
    :ok
  end

  test "merged blocker notice resolves churn once and opens once" do
    assert :ok = Attention.open(:optimistic_blocker_failed, "11", %{blocker: "10", cause: :churn, action: :none, severity: "info"})
    calls = Agent.start_link(fn -> [] end) |> elem(1)

    attention = fn action, dep, payload ->
      Agent.update(calls, &(&1 ++ [{action, dep, payload}]))
      if action == :resolve, do: Attention.resolve(:optimistic_blocker_failed, dep), else: Attention.open(:optimistic_blocker_failed, dep, payload)
    end

    assert :ok =
             OptimisticLedger.record_start("11", %{
               attempt_id: "guard-merged-notice",
               start_trigger: :pr_opened,
               started_at_ms: 100,
               blockers: [%{"id" => "10", "pr_number" => 77, "merged_at_ms" => 1_000}]
             })

    opts = [ledger: OptimisticLedger, attention: attention]
    state = OptimisticGuardEffects.execute(%State{}, {:merged_notice, "11", "10"}, opts)
    assert state.tracker_tasks == %{}
    assert Agent.get(calls, &Enum.map(&1, fn {action, _, _} -> action end)) == [:resolve, :open]
    assert {:ok, row} = OptimisticLedger.get("11")
    assert hd(row["blockers"])["merged_notice_emitted"]

    OptimisticGuardEffects.execute(state, {:merged_notice, "11", "10"}, opts)
    assert Agent.get(calls, &Enum.map(&1, fn {action, _, _} -> action end)) == [:resolve, :open]
    Agent.stop(calls)
  end
end
