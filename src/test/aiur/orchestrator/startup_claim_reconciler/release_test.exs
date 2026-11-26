defmodule Aiur.Orchestrator.StartupClaimReconciler.ReleaseTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.StartupClaimReconciler.Release

  # open-games, 2026-11-20: the daemon sat at its hourly Core ceiling, so the
  # label check after an orphan release came back held. The hold arrived wrapped
  # in `:state_label_verification_failed`, counted as a failed attempt, and after
  # three of them the claim stayed in-progress until someone stripped the label
  # by hand. A budget hold is a reason to wait, never a spent attempt.

  @hold {:github, :local_hold, %{reason: {:aiur, :locally_held, %{reason: :actor_budget, resource: "core"}}, hold: %{reason: :actor_budget, resource: "core"}}}

  defp run(result), do: Release.run(%Issue{id: "1", identifier: "30"}, release_fun: fn _issue, _opts -> result end)

  test "a budget hold inside the label check defers the release" do
    assert {:defer, {:state_label_verification_failed, @hold}} = run({:error, {:state_label_verification_failed, @hold}})
  end

  test "a held transport read inside the label check defers the release" do
    transport = {:github, :transport, %{reason: {:aiur, :locally_held, %{reason: :actor_budget}}}}
    assert {:defer, _reason} = run({:error, {:state_label_verification_failed, transport}})
  end

  test "a real label check failure still spends an attempt" do
    assert {:error, {:state_label_verification_failed, {:github, :status, 422}}} = run({:error, {:state_label_verification_failed, {:github, :status, 422}}})
  end
end
