defmodule Aiur.Gateway.LivenessTest do
  use ExUnit.Case, async: true

  alias Aiur.Gateway.Liveness

  @threshold 180_000

  defp view(rows), do: {:ok, %{instances: rows}}
  defp row(id, age, extra \\ %{}), do: Map.merge(%{gateway_id: id, age_ms: age, current?: false, leader?: false}, extra)
  defp me, do: row("me", 0, %{current?: true, leader?: true})

  defp run(ages_by_tick, opts \\ []) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> ages_by_tick end)

    base = [
      threshold_ms: @threshold,
      roster_fun: fn -> Agent.get_and_update(agent, fn [h | t] -> {view([me() | h]), t} end) end,
      emit: fn topic, o -> send(test, {:emit, topic, o[:needs_attention]}) && :ok end,
      condition_state_fun: fn _ -> :unknown end
    ]

    state = %{alerted: nil, opts: Keyword.merge(base, opts)}
    Enum.reduce(ages_by_tick, state, fn _, s -> Liveness.tick(s) end)
  end

  defp emits(acc \\ []) do
    receive do
      {:emit, t, a} -> emits([{t, a} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "silent 4 minutes alerts exactly once across ticks" do
    run([[row("g1", 240_000)], [row("g1", 270_000)]])
    assert emits() == [{"system.gateway.g1.offline", true}]
  end

  test "silent 2 minutes then back raises nothing" do
    run([[row("g1", 120_000)], [row("g1", 1_000)]])
    assert emits() == []
  end

  test "back online then offline again alerts a second time, recovery is silent" do
    run([[row("g1", 240_000)], [row("g1", 1_000)], [row("g1", 240_000)]])

    assert emits() == [
             {"system.gateway.g1.offline", true},
             {"system.gateway.g1.offline.resolved", false},
             {"system.gateway.g1.offline", true}
           ]
  end

  test "a silent sibling daemon of our own gateway is not an outage" do
    run([[row("me", 240_000)]])
    assert emits() == []
  end

  test "freshest instance of a gateway wins" do
    run([[row("g1", 240_000), row("g1", 5_000)]])
    assert emits() == []
  end

  test "a restart during an open outage does not re-alert" do
    run([[row("g1", 240_000)]], condition_state_fun: fn "system.gateway.g1.offline" -> :firing end)
    assert emits() == []
  end

  test "a failed emit retries on the next tick" do
    {:ok, n} = Agent.start_link(fn -> 0 end)
    emit = fn t, _ -> if Agent.get_and_update(n, &{&1, &1 + 1}) == 0, do: :error, else: send(self(), {:ok, t}) && :ok end
    run([[row("g1", 240_000)], [row("g1", 240_000)]], emit: emit)
    assert Agent.get(n, & &1) == 2
  end

  test "a non-leader never alerts" do
    state = %{alerted: nil, opts: [threshold_ms: @threshold, roster_fun: fn -> view([row("me", 0, %{current?: true}), row("g1", 240_000)]) end, emit: fn _, _ -> flunk("emitted") end]}
    Liveness.tick(state)
  end
end
