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
    assert {50, 25, 12} = Shared.fallback_limits({100, 50, 25}, %{available?: false, live_count: 1})
  end

  test "two daemon budget clients share one admission ceiling" do
    {:ok, store} = Agent.start_link(fn -> 0 end)
    reset_at = DateTime.add(DateTime.utc_now(), 3_600, :second)

    admit = fn _lease_id, _credential, "graphql", _consumer, limit, points ->
      Agent.get_and_update(store, fn used ->
        if used + points <= limit do
          {{:ok, :admitted}, used + points}
        else
          {{:ok, {:held, reset_at}}, used}
        end
      end)
    end

    opts = [
      coordination_status_fun: fn -> %{available?: true, live_count: 2} end,
      github_budget_admit_fun: admit,
      request_points: 60,
      release_fun: fn _lease_id, _key -> :ok end,
      daemon_graphql_limit_per_hour: 100
    ]

    first = %{url: "https://api.github.com/graphql", credential_key: "shared-app-credential"}
    second = %{url: "https://api.github.com/graphql", credential_key: "shared-app-credential"}

    assert {:ok, %{id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}} =
             Shared.grant_or_hold("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", first, "credential", opts)

    assert {:hold, %{reason: :shared_budget, reset_at: ^reset_at}} =
             Shared.grant_or_hold("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", second, "credential", opts)

    assert Agent.get(store, & &1) == 60
  end

  test "a shared admission outage keeps the already-divided local grant" do
    assert {:ok, %{id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}} =
             Shared.grant_or_hold(
               "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               %{url: "https://api.github.com/graphql"},
               "credential",
               coordination_status_fun: fn -> %{available?: true, live_count: 2} end,
               github_budget_admit_fun: fn _, _, _, _, _, _ -> {:error, :database_down} end
             )
  end
end
