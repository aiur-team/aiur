defmodule AiurWeb.DeviceVoiceTicket.UsedTest do
  use ExUnit.Case, async: true

  alias AiurWeb.DeviceVoiceTicket.Used

  setup do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, System.system_time(:millisecond))
    server = start_supervised!({Used, name: nil, now: fn -> :atomics.get(clock, 1) end})
    %{server: server, clock: clock, now: :atomics.get(clock, 1)}
  end

  test "a ticket hash can be claimed only once while a fresh hash still succeeds", %{server: server, now: now} do
    hash = :crypto.hash(:sha256, "first-ticket")
    assert :ok = Used.claim(hash, now + 60_000, server)
    assert {:error, :already_used} = Used.claim(hash, now + 60_000, server)
    assert :ok = Used.claim(:crypto.hash(:sha256, "fresh-ticket"), now + 60_000, server)
  end

  test "expired tickets are refused even if never claimed", %{server: server, now: now} do
    for expires_at <- [now - 1, now] do
      assert {:error, :expired} = Used.claim(:crypto.hash(:sha256, "expired-#{expires_at}"), expires_at, server)
    end
  end

  test "concurrent claims admit exactly one caller", %{server: server, now: now} do
    hash = :crypto.hash(:sha256, "raced-ticket")
    claims = for _ <- 1..8, do: Task.async(fn -> Used.claim(hash, now + 60_000, server) end)
    results = Enum.map(claims, &Task.await/1)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_used})) == 7
  end

  test "the sweep removes expired hashes and preserves unexpired replay protection", %{server: server, clock: clock, now: now} do
    expired = :crypto.hash(:sha256, "expires-first")
    active = :crypto.hash(:sha256, "expires-later")
    assert :ok = Used.claim(expired, now + 1, server)
    assert :ok = Used.claim(active, now + 60_000, server)
    :atomics.put(clock, 1, now + 1)
    send(server, :sweep)
    %{table: table} = :sys.get_state(server)
    assert :ets.info(table, :size) == 1
    assert {:error, :already_used} = Used.claim(active, now + 60_000, server)
    assert {:error, :expired} = Used.claim(expired, now + 1, server)
  end

  test "claims fail closed when the replay store is unavailable", %{server: server, now: now} do
    stop_supervised!(Used)
    assert {:error, :unavailable} = Used.claim(:crypto.hash(:sha256, "unavailable"), now + 60_000, server)
  end
end
