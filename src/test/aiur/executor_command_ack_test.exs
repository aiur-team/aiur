Code.require_file("../support/decision_store_case.ex", __DIR__)

defmodule Aiur.ExecutorCommandAckTest do
  use Aiur.DecisionStoreCase, async: false
  import ExUnit.CaptureIO
  alias Aiur.Commands.Routing.Policy

  setup %{dir: dir} do
    previous_workflow = Aiur.Workflow.workflow_file_path()
    File.mkdir_p!(dir)
    workflow = Path.join(dir, "test.yaml")
    Aiur.TestSupport.write_workflow_file!(workflow)
    Aiur.Workflow.set_workflow_file_path(workflow)
    on_exit(fn -> Aiur.Workflow.set_workflow_file_path(previous_workflow) end)
    pid = start_supervised!({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000})
    {:ok, %{decision: decision}} = request(pid, %{question: "Which scope?", blocking: false})
    %{pid: pid, decision: decision, at: DateTime.utc_now()}
  end

  test "explicit ack persists attribution and only cancels the acknowledgement deadline", %{pid: pid, decision: d, at: at} do
    route = %{policy: :executor_first, state: :with_executor, cause: nil, at: at, actor: %{kind: :system, id: "routing"}}
    assert {:ok, _} = DecisionStore.record_command_fact(d.decision_id, :routed, route, server: pid)
    params = [decision_id: d.decision_id, executor_id: "executor-one"]
    deps = [decision_store: pid, now: at]
    assert capture_io(fn -> assert ExecutorCommandCLI.ack(params, deps) == 0 end) == "acknowledged #{d.decision_id}\n"
    assert {:ok, acked} = DecisionStore.get(d.decision_id, pid)
    assert acked.executor_acknowledged_at == at
    assert {acked.route_state, acked.decision_status, acked.answer} == {:with_executor, :open, nil}
    config = %{ack_ms: 300_000, answer_ms: 900_000, urgent_factor: 0.5}
    assert Policy.escalation_due(acked, DateTime.add(at, 360), config) == {:next, DateTime.add(at, 900)}
    assert Policy.escalation_due(acked, DateTime.add(at, 900), config) == {:due, :executor_answer_timeout, DateTime.add(at, 900)}
    assert {:ok, history} = DecisionStore.audit_history(d.decision_id, pid)
    assert [%{data: %{executor_id: "executor-one", via: :explicit, at: ^at}}] = Enum.filter(history, &(&1.type == :executor_acknowledged))
  end

  test "duplicate ack reports already acknowledged without a second fact", %{pid: pid, decision: d, at: at} do
    params = [decision_id: d.decision_id]
    capture_io(fn -> assert ExecutorCommandCLI.ack(params, decision_store: pid, now: at) == 0 end)
    assert capture_io(fn -> assert ExecutorCommandCLI.ack(params, decision_store: pid, now: DateTime.add(at, 60)) == 0 end) == "already acknowledged #{d.decision_id}\n"
    assert {:ok, history} = DecisionStore.audit_history(d.decision_id, pid)
    assert [%{data: %{executor_id: "aiur-cli", at: ^at}}] = Enum.filter(history, &(&1.type == :executor_acknowledged))
  end

  test "ack after escalation retains the human route", %{pid: pid, decision: d, at: at} do
    route = %{policy: :executor_first, state: :with_executor, cause: nil, at: at, actor: %{kind: :system, id: "routing"}}
    assert {:ok, _} = DecisionStore.record_command_fact(d.decision_id, :routed, route, server: pid)
    escalation = %{cause: :executor_escalated, at: at, detail: "Needs operator", actor: %{kind: :executor, id: "executor-one"}}
    assert {:ok, _} = DecisionStore.record_command_fact(d.decision_id, :escalated, escalation, server: pid)
    capture_io(fn -> assert ExecutorCommandCLI.ack([decision_id: d.decision_id], decision_store: pid, now: at) == 0 end)
    assert {:ok, acked} = DecisionStore.get(d.decision_id, pid)
    assert {acked.route_state, acked.executor_acknowledged_at} == {:with_human, at}
  end

  test "ack validates identifiers and reports missing decisions and failed writes", %{pid: pid} do
    for params <- [[decision_id: "bad"], [decision_id: "dec_0123456789abcdef", executor_id: " "], [decision_id: "dec_0123456789abcdef", executor_id: String.duplicate("a", 257)], :invalid] do
      assert capture_io(:stderr, fn -> assert ExecutorCommandCLI.ack(params, record_fact_fun: fn _, _, _, _ -> flunk("invalid input reached store") end) == 64 end) =~ "executor-ack"
    end

    assert capture_io(:stderr, fn -> assert ExecutorCommandCLI.ack([decision_id: "dec_0123456789abcdef"], decision_store: pid) == 1 end) =~ "could not find decision"
    assert capture_io(:stderr, fn -> assert ExecutorCommandCLI.ack([decision_id: "dec_0123456789abcdef"], record_fact_fun: fn _, _, _, _ -> {:error, :read_only} end) == 1 end) =~ "read_only"
  end

  for via <- [:answer, :supersede, :escalate, :moot] do
    test "#{via} writes an implicit acknowledgement after success", %{pid: pid, at: at} do
      via = unquote(via)

      assert {:ok, %{decision: actionable}} =
               request(pid, %{
                 question: "Proceed with established policy?",
                 blocking: false,
                 authority: "supervisor_allowed",
                 reversibility: "reversible",
                 options: [%{id: "yes", label: "Yes"}]
               })

      prepare_supersede(via, actionable.decision_id, pid)

      d = actionable
      params = params(d.decision_id, via)
      deps = [decision_store: pid, now: at]
      capture_io(fn -> assert act(via, params, deps) == 0 end)
      assert {:ok, stored} = DecisionStore.get(d.decision_id, pid)
      assert stored.executor_acknowledged_at == at
      assert {:ok, history} = DecisionStore.audit_history(d.decision_id, pid)
      assert [%{data: %{executor_id: "executor-one", via: ^via, at: ^at}}] = Enum.filter(history, &(&1.type == :executor_acknowledged))
    end
  end

  test "implicit write errors and exits are logged without changing successful action status", %{decision: d, pid: pid} do
    for failure <- [:error, :exit, :raise] do
      writer = fn _, _, _, _ ->
        case failure do
          :error -> {:error, :read_only}
          :exit -> exit(:store_down)
          :raise -> raise "writer failed"
        end
      end

      deps = success_deps(pid, :answer) ++ [record_fact_fun: writer]
      log = capture_log(fn -> capture_io(fn -> assert act(:answer, params(d.decision_id, :answer), deps) == 0 end) end)
      assert log =~ "Executor acknowledgement failed"
    end
  end

  # Future regression guard: failed actions must never fabricate attention evidence.
  test "failed actions do not attempt an acknowledgement", %{decision: d} do
    for via <- [:answer, :supersede, :escalate, :moot] do
      deps = [record_fact_fun: fn _, _, _, _ -> flunk("failed action acknowledged") end] ++ failure_deps(via)
      capture_io(:stderr, fn -> assert act(via, params(d.decision_id, via), deps) == 1 end)
    end
  end

  defp prepare_supersede(:supersede, id, pid) do
    assert {:ok, _} = DecisionStore.answer(id, %{"expected_version" => 1, "option_id" => "yes", "idempotency_key" => "original"}, [actor: %{kind: :executor, id: "executor-one"}], pid)
  end

  defp prepare_supersede(_via, _id, _pid), do: :ok

  defp params(id, via) do
    [
      decision_id: id,
      executor_id: "executor-one",
      expected_version: 1,
      option_id: "yes",
      rationale: "Known policy",
      idempotency_key: "ack-test",
      supersede: via == :supersede,
      reason: "Needs operator",
      reason_class: "ticket_closed"
    ]
  end

  defp act(:supersede, params, deps), do: ExecutorCommandCLI.answer(params, deps)
  defp act(via, params, deps), do: apply(ExecutorCommandCLI, via, [params, deps])
  defp success_deps(pid, via), do: [decision_store: pid] ++ action_deps(via, {:ok, %{status: if(via == :escalate, do: :opened, else: :accepted)}})
  defp failure_deps(via), do: action_deps(via, {:error, :not_found})
  defp action_deps(:answer, result), do: [answer_fun: fn _, _, _, _ -> result end]
  defp action_deps(:supersede, result), do: [supersede_fun: fn _, _, _, _ -> result end]
  defp action_deps(:escalate, result), do: [escalate_fun: fn _, _, _ -> result end]
  defp action_deps(:moot, result), do: [moot_fun: fn _, _, _, _ -> result end]
end
