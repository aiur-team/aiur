defmodule Aiur.AgentPubSub.FleetRefreshTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.AgentPubSub.FleetRefresh

  test "a missing fleet table does not crash broadcasts to other consumers" do
    owner = Process.whereis(FleetRefresh)
    :ok = FleetRefresh.register(self())
    latch = :atomics.new(1, [])
    message = {:running_changed, [%{identifier: "3875", title: "running"}]}

    :sys.replace_state(owner, fn state ->
      :ets.rename(FleetRefresh, :fleet_refresh_restart_test)
      state
    end)

    try do
      assert :ok = FleetRefresh.dispatch([{self(), {:fleet_refresh, latch}}, {self(), nil}], :none, message)
      assert_received ^message
    after
      :sys.replace_state(owner, fn state ->
        :ets.rename(:fleet_refresh_restart_test, FleetRefresh)
        state
      end)
    end
  end

  test "a captured dispatch cannot retain summaries after subscriber death" do
    owner = Process.whereis(FleetRefresh)
    :erlang.trace(owner, true, [:receive])
    on_exit(fn -> if Process.alive?(owner), do: :erlang.trace(owner, false, [:receive]) end)
    subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
    :ok = FleetRefresh.register(subscriber)
    latch = :atomics.new(1, [])
    captured_entries = [{subscriber, {:fleet_refresh, latch}}]
    summaries = [%{identifier: "3875", title: "running"}]
    assert :ok = FleetRefresh.dispatch(captured_entries, :none, {:running_changed, summaries})
    assert FleetRefresh.latest(subscriber) == summaries

    send(subscriber, :stop)
    receive_barrier({:trace, ^owner, :receive, {:DOWN, _ref, :process, ^subscriber, :normal}})
    :sys.get_state(owner)
    assert FleetRefresh.latest(subscriber) == nil
    assert :ok = FleetRefresh.dispatch(captured_entries, :none, {:running_changed, summaries})
    assert FleetRefresh.latest(subscriber) == nil
  end
end
