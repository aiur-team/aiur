defmodule Aiur.Capacity.LedgerStoreTest do
  @moduledoc "The ledger at dispatch (#7890): atomic claims, holds tied to live agents, rebuilt on adoption."

  use ExUnit.Case, async: true

  alias Aiur.Capacity.LedgerStore
  alias Aiur.CodingAgent.CapacityGate
  alias Aiur.Issue

  @t0 ~U[2026-11-10 12:00:00Z]
  @policy %{
    sources: %{"claude" => %{billing: "subscription", reserve: %{percent: 30, accounts: ["default"]}}},
    default_burn_percent_per_hour: 6
  }
  # A subscription with no reserve: every claim holds, none is refused.
  @open %{sources: %{"claude" => %{billing: "subscription"}}}
  @claude %{backend: "claude", account: nil, route: "claude"}

  setup do
    name = :"ledger_store_#{System.unique_integer([:positive])}"
    start_supervised!({LedgerStore, name: name})
    %{server: name}
  end

  defp reading(used, at), do: %{windows: %{"seven_day" => used}, observed_at: at, age_seconds: 0, source: "meter"}

  defp verdict(server, reading) do
    readings = %{{"claude", nil} => reading}
    [entry] = CapacityGate.evaluate([@claude], readings, capacity_policy: @policy, ledger_store: server, usage_floor: 0).entries
    {entry.verdict, entry.reason}
  end

  defp claim(server, id, at, owner \\ self()),
    do: LedgerStore.claim(%Issue{id: id, selected_backend: "claude"}, server: server, now: at, capacity_policy: @policy, owner: owner)

  defp holds(server), do: Map.keys(LedgerStore.ledger(server).holds)

  defp agent, do: spawn(fn -> receive do: (reason -> exit(reason)) end)

  defp stop(server, pid, reason) do
    ref = Process.monitor(pid)
    send(pid, reason)
    assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}, 1000
    # A call after the exit is ordered behind the store's :DOWN.
    LedgerStore.ledger(server)
  end

  test "a second claim in the same poll interval sees the first claim's hold", %{server: server} do
    at = reading(64, @t0)
    assert verdict(server, at) == {:allow, nil}
    assert claim(server, "1", DateTime.add(@t0, 60)) == :ok
    # 36% left minus one agent-hour at 6%/h is 30%: at the reserve.
    assert verdict(server, at) == {:hold, :reserve}
    assert claim(server, "2", DateTime.add(@t0, 61)) == {:hold, :reserve}
    assert holds(server) == ["1"]
  end

  test "a reserved account with no folded reading fails closed", %{server: server} do
    assert claim(server, "1", @t0) == {:hold, :reading_unknown}
    assert holds(server) == []
  end

  test "two dispatchers racing one reserve slot: exactly one claims", %{server: server} do
    # 36% left: one hold (6%) leaves 30%, at the reserve, so a second is refused.
    verdict(server, reading(64, @t0))
    owner = agent()

    results =
      for id <- ["a", "b"] do
        Task.async(fn -> claim(server, id, DateTime.add(@t0, 60), owner) end)
      end
      |> Enum.map(&Task.await/1)

    assert Enum.sort(results) == [:ok, {:hold, :reserve}]
    assert length(holds(server)) == 1
  end

  test "a fresh reading folds the older hold", %{server: server} do
    verdict(server, reading(64, @t0))
    claim(server, "1", DateTime.add(@t0, 60))
    assert verdict(server, reading(65, DateTime.add(@t0, 300))) == {:allow, nil}
    assert [%{ticket: "1", estimate: 6, actual: actual}] = LedgerStore.ledger(server).reconciles
    assert_in_delta actual, 1 / (240 / 3600), 0.01
  end

  for reason <- [:normal, :crash, :shutdown] do
    test "the hold is released when the agent exits with #{inspect(reason)}", %{server: server} do
      assert CapacityGate.claim(%Issue{id: "1", selected_backend: "claude"}, capacity_policy: @open, ledger_store: server) == :ok
      pid = agent()
      CapacityGate.started("1", %{pid: pid}, ledger_store: server)
      assert holds(server) == ["1"]
      stop(server, pid, unquote(reason))
      assert holds(server) == []
    end
  end

  test "a dispatch that starts no agent releases its claim", %{server: server} do
    verdict(server, reading(10, @t0))
    claim(server, "1", DateTime.add(@t0, 60))
    CapacityGate.started("1", nil, ledger_store: server)
    assert holds(server) == []
  end

  test "the dispatcher's exit releases a claim never handed to an agent", %{server: server} do
    verdict(server, reading(10, @t0))
    owner = agent()
    claim(server, "1", DateTime.add(@t0, 60), owner)
    stop(server, owner, :crash)
    assert holds(server) == []
  end

  test "a re-claim is not released by the previous owner's exit", %{server: server} do
    verdict(server, reading(10, @t0))
    old = agent()
    claim(server, "1", DateTime.add(@t0, 60), old)
    claim(server, "1", DateTime.add(@t0, 61))
    stop(server, old, :normal)
    assert holds(server) == ["1"]
  end

  test "adoption rebuilds holds tied to the adopted workers", %{server: server} do
    pid = agent()
    CapacityGate.rebuild_holds([%{issue: %Issue{id: "7", selected_backend: "claude"}, pid: pid, started_at: DateTime.add(@t0, 60)}], ledger_store: server, capacity_policy: @policy)
    assert verdict(server, reading(64, @t0)) == {:hold, :reserve}
    stop(server, pid, :normal)
    assert verdict(server, reading(64, @t0)) == {:allow, nil}
  end

  test "an unreserved metered source records no hold", %{server: server} do
    LedgerStore.claim(%Issue{id: "2", selected_backend: "openrouter"}, server: server, now: @t0, capacity_policy: @policy)
    assert holds(server) == []
  end

  test "every call is a no-op when the store is not running or not configured" do
    assert LedgerStore.policy_holds([@claude], %{}, :no_such_store) == []
    assert LedgerStore.release("1", :no_such_store) == :ok
    assert CapacityGate.claim(%Issue{id: "1", selected_backend: "claude"}, capacity_policy: @policy) == :ok
  end
end
