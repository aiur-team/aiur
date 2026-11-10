defmodule Aiur.Capacity.LedgerStoreTest do
  @moduledoc "The ledger at dispatch (#7890): holds read by the capacity gate, folded by fresh readings, rebuilt on adoption."

  use ExUnit.Case, async: true

  alias Aiur.Capacity.LedgerStore
  alias Aiur.CodingAgent.CapacityGate
  alias Aiur.Issue

  @t0 ~U[2026-11-10 12:00:00Z]
  @policy %{
    sources: %{"claude" => %{billing: "subscription", reserve: %{percent: 30, accounts: ["default"]}}},
    default_burn_percent_per_hour: 6
  }
  @claude %{backend: "claude", account: nil, route: "claude"}

  setup do
    name = :"ledger_store_#{System.unique_integer([:positive])}"
    start_supervised!({LedgerStore, name: name})
    %{server: name}
  end

  defp reading(used, at), do: %{windows: %{"seven_day" => used}, observed_at: at, age_seconds: 0, source: "meter"}

  defp verdict(server, reading) do
    readings = %{{"claude", nil} => reading}
    holds = LedgerStore.policy_holds([@claude], readings, server)
    [entry] = CapacityGate.evaluate([@claude], readings, capacity_policy: @policy, capacity_holds: holds, usage_floor: 0).entries
    {entry.verdict, entry.reason}
  end

  defp dispatch(server, id, at), do: LedgerStore.hold(%Issue{id: id, selected_backend: "claude"}, server: server, now: at, capacity_policy: @policy)

  test "a second claim in the same poll interval sees the first claim's hold", %{server: server} do
    at = reading(64, @t0)
    assert verdict(server, at) == {:allow, nil}
    dispatch(server, "1", DateTime.add(@t0, 60))
    # 36% left minus one agent-hour at 6%/h is 30%: at the reserve.
    assert verdict(server, at) == {:hold, :reserve}
  end

  test "a fresh reading folds the older hold", %{server: server} do
    verdict(server, reading(64, @t0))
    dispatch(server, "1", DateTime.add(@t0, 60))
    assert verdict(server, reading(65, DateTime.add(@t0, 300))) == {:allow, nil}
    assert [%{ticket: "1", estimate: 6, actual: actual}] = LedgerStore.ledger(server).reconciles
    assert_in_delta actual, 1 / (240 / 3600), 0.01
  end

  test "adoption rebuilds holds from running agents and teardown releases them", %{server: server} do
    LedgerStore.rebuild([%{issue: %Issue{id: "7", selected_backend: "claude"}, started_at: DateTime.add(@t0, 60)}], server: server, capacity_policy: @policy)
    assert verdict(server, reading(64, @t0)) == {:hold, :reserve}
    LedgerStore.release("7", server)
    assert verdict(server, reading(64, @t0)) == {:allow, nil}
  end

  test "an unreserved metered source records no hold", %{server: server} do
    LedgerStore.hold(%Issue{id: "2", selected_backend: "openrouter"}, server: server, now: @t0, capacity_policy: @policy)
    assert LedgerStore.ledger(server).holds == %{}
  end

  test "every call is a no-op when the store is not running" do
    assert LedgerStore.policy_holds([@claude], %{}, :no_such_store) == []
    assert LedgerStore.release("1", :no_such_store) == :ok
  end
end
