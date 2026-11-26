defmodule Aiur.DecisionStore.ClaimsTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionStore.Claims

  @now ~U[2026-11-06 12:00:00Z]
  @later DateTime.add(@now, 1800, :second)

  defp decision(claim \\ nil), do: %{decision_status: :open, answer: nil, executor_claim: claim}
  defp live_claim(id), do: %{executor_id: id, claimed_at: @now, expires_at: @later}

  test "a second Executor's claim is refused with the claimant's id" do
    assert {:error, {:claimed, "exec-a", @later}} = Claims.claim(decision(live_claim("exec-a")), %{executor_id: "exec-b", now: @now, expires_at: @later})
  end

  test "the claimant renews, and an expired claim is treated as absent" do
    assert {:ok, %{executor_id: "exec-a"}} = Claims.claim(decision(live_claim("exec-a")), %{executor_id: "exec-a", now: @now, expires_at: @later})
    assert {:ok, %{executor_id: "exec-b"}} = Claims.claim(decision(live_claim("exec-a")), %{executor_id: "exec-b", now: DateTime.add(@later, 1, :second), expires_at: @later})
  end

  test "a closed Decision cannot be claimed" do
    assert {:error, :command_not_open} = Claims.claim(%{decision() | answer: %{}}, %{executor_id: "exec-a", now: @now, expires_at: @later})
  end

  test "only the claimant releases" do
    assert {:ok, :released} = Claims.release(decision(live_claim("exec-a")), %{executor_id: "exec-a", now: @now})
    assert {:error, {:claimed, "exec-a", @later}} = Claims.release(decision(live_claim("exec-a")), %{executor_id: "exec-b", now: @now})
    assert {:error, :not_claimed} = Claims.release(decision(), %{executor_id: "exec-a", now: @now})
  end

  test "check_actor refuses other Executors but lets the claimant and humans through" do
    claimed = decision(live_claim("exec-a"))
    assert {:error, {:claimed, "exec-a", @later}} = Claims.check_actor(claimed, %{kind: :executor, id: "exec-b"}, @now)
    assert :ok = Claims.check_actor(claimed, %{kind: :executor, id: "exec-a"}, @now)
    assert :ok = Claims.check_actor(claimed, %{kind: :operator, id: "kevin"}, @now)
    assert :ok = Claims.check_actor(claimed, %{kind: :executor, id: "exec-b"}, DateTime.add(@later, 1, :second))
  end
end
