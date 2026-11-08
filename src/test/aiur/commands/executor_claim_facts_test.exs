Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.ExecutorClaimFactsTest do
  use Aiur.DecisionStoreCase, async: false

  setup %{dir: dir} do
    pid = start_supervised_store!(dir)
    {:ok, %{decision: decision}} = request(pid, %{question: "Who takes this?", blocking: false})
    %{pid: pid, decision: decision, at: DateTime.utc_now()}
  end

  defp fact(pid, decision, type, data), do: DecisionStore.record_command_fact(decision.decision_id, type, data, server: pid)
  defp claim(id, at), do: %{executor_id: id, at: at, expires_at: DateTime.add(at, 600)}
  defp store_spec(dir), do: Supervisor.child_spec({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end}, id: make_ref(), restart: :temporary)

  test "a claim is journaled, survives restart, and refuses another Executor's answer with the claimant", %{pid: pid, decision: d, at: at, dir: dir} do
    assert {:ok, %{status: :accepted, decision: claimed}} = fact(pid, d, :executor_claimed, claim("exec-a", at))
    assert claimed.executor_claim.executor_id == "exec-a"
    assert claimed.content_hash == d.content_hash
    assert {:error, {:invalid_transition, {:claimed, "exec-a", _}}} = fact(pid, d, :executor_claimed, claim("exec-b", at))

    GenServer.stop(pid)
    replayed = start_supervised!(store_spec(dir))
    payload = %{"idempotency_key" => "k", "expected_version" => 1, "custom_response" => "Proceed"}
    assert {:error, {:claimed, "exec-a", _}} = answer(replayed, d.decision_id, payload, actor: %{kind: :executor, id: "exec-b"})
    assert {:ok, _} = answer(replayed, d.decision_id, payload, actor: %{kind: :executor, id: "exec-a"})
  end

  test "release clears the claim for others", %{pid: pid, decision: d, at: at} do
    assert {:ok, _} = fact(pid, d, :executor_claimed, claim("exec-a", at))
    assert {:error, {:invalid_transition, {:claimed, "exec-a", _}}} = fact(pid, d, :executor_claim_released, %{executor_id: "exec-b", reason: :released, at: at})
    assert {:ok, %{decision: released}} = fact(pid, d, :executor_claim_released, %{executor_id: "exec-a", reason: :released, at: at})
    assert released.executor_claim == nil
    assert {:ok, _} = fact(pid, d, :executor_claimed, claim("exec-b", at))
  end
end
