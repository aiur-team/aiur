defmodule Aiur.AgentRunner.BudgetHoldExitTest do
  use ExUnit.Case, async: true

  test "workspace preflight hold survives the worker monitor boundary with its reset" do
    hold = %{reason: :actor_budget, resource: "none", reset_at: ~U[2026-09-29 10:51:12Z]}

    reason =
      {:workspace_github_connectivity_failed, "/unused/workspace",
       {:github_auth_preflight_failed, %{classification: :local_hold, detail: %{hold: hold}}}}

    {pid, ref} = spawn_monitor(fn -> Aiur.AgentRunner.fail_run(reason, "diagnostic") end)

    assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}
    assert Aiur.Orchestrator.AutoResume.classify(reason) == :local_budget_hold
  end

  test "permanent failure retains the ordinary exception contract" do
    assert_raise RuntimeError, "permission denied", fn ->
      Aiur.AgentRunner.fail_run({:github, :permission, %{}}, "permission denied")
    end
  end
end
