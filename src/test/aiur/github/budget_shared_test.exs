defmodule Aiur.GitHub.BudgetSharedTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Budget.Shared

  test "a failed shared hold read falls through to per-instance local limits" do
    request = %{url: "https://api.github.com/repos/owner/repo/issues"}

    assert :clear =
             Shared.hold_status(request, "credential-key",
               coordination_status_fun: fn -> %{available?: true, live_count: 3} end,
               github_budget_hold_fun: fn _credential, _resource ->
                 {:error, {:store_unavailable, :connection_lost}}
               end
             )

    assert {100, 50, 25} = Shared.fallback_limits({300, 150, 75}, %{available?: false, live_count: 3})
  end
end
