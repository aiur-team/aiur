defmodule Aiur.Instance.DispatchClaimTest do
  use ExUnit.Case, async: true

  alias Aiur.Instance.DispatchClaim

  test "two orchestrators racing for one todo ticket start exactly one workspace" do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    parent = self()

    claim_fun = fn ticket_key ->
      Agent.get_and_update(store, fn claims ->
        case Map.fetch(claims, ticket_key) do
          {:ok, _owner} -> {:held, claims}
          :error -> {:acquired, Map.put(claims, ticket_key, true)}
        end
      end)
    end

    tasks =
      for name <- [:left, :right] do
        Task.async(fn ->
          DispatchClaim.call("owner/repo#42", fn -> send(parent, {:workspace_started, name}) end, claim_fun: claim_fun)
        end)
      end

    results = Enum.map(tasks, &Task.await/1)
    started = collect_started([])

    assert Enum.count(results, &match?({:ok, :acquired, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :shared_lease_held})) == 1
    assert length(started) == 1
  end

  test "an unavailable store prevents workspace dispatch" do
    result =
      DispatchClaim.call("owner/repo#43", fn -> send(self(), :workspace_started) end, claim_fun: fn _ -> {:error, :offline} end)

    assert result == {:error, {:shared_lease_unavailable, :offline}}
    refute_receive :workspace_started, 0
  end

  test "an expired lease allows another orchestrator to dispatch" do
    {:ok, leases} = Agent.start_link(fn -> %{} end)
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    claim_fun = fn key ->
      now = Agent.get(clock, & &1)

      Agent.get_and_update(leases, fn current ->
        case Map.get(current, key) do
          %{expires_at: expiry} when expiry > now -> {:held, current}
          _ -> {:acquired, Map.put(current, key, %{expires_at: now + 100})}
        end
      end)
    end

    assert {:ok, :acquired, :first} =
             DispatchClaim.call("owner/repo#44", fn -> :first end, claim_fun: claim_fun)

    assert {:error, :shared_lease_held} =
             DispatchClaim.call("owner/repo#44", fn -> :duplicate end, claim_fun: claim_fun)

    Agent.update(clock, fn _ -> 101 end)

    assert {:ok, :acquired, :resumed} =
             DispatchClaim.call("owner/repo#44", fn -> :resumed end, claim_fun: claim_fun)
  end

  defp collect_started(names) do
    receive do
      {:workspace_started, name} -> collect_started([name | names])
    after
      0 -> names
    end
  end
end
