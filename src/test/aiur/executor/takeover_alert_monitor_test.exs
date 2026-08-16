defmodule Aiur.Executor.TakeoverAlert.MonitorTest do
  @moduledoc """
  Injected-clock boundary/cadence/persistence tests for the Executor takeover
  advisory monitor. Every tick is driven manually; the clock is an Agent the
  test controls. The only "sleep" is a short deterministic poll that waits for
  a store write to land before the test advances the clock, so a tick can never
  be processed against an already-advanced clock.
  """

  use ExUnit.Case, async: false

  alias Aiur.Executor.TakeoverAlert.Monitor
  alias Aiur.Executor.TakeoverAlert.Store

  @t0 ~U[2026-01-01 00:00:00Z]

  defp hours(n), do: DateTime.add(@t0, round(n * 3600), :second)

  defp unique_name(prefix) do
    Module.concat(__MODULE__, :"#{prefix}#{System.unique_integer([:positive])}")
  end

  defp start_store(state_dir) do
    name = unique_name("Store")
    {:ok, pid} = Store.start_link(name: name, state_dir: state_dir)
    %{pid: pid, name: name}
  end

  defp start_clock(initial) do
    {:ok, pid} = Agent.start_link(fn -> initial end)
    now_fun = fn -> Agent.get(pid, & &1) end
    set_time = fn time -> Agent.update(pid, fn _ -> time end) end
    {now_fun, set_time, pid}
  end

  defp healthy_ticket(identifier) do
    %{
      identifier: identifier,
      title: "Ticket #{identifier}",
      url: "https://example.com/#{identifier}",
      terminal?: false,
      in_scope?: true,
      live_owner?: true
    }
  end

  defp start_monitor(store_name, now_fun, settings, snapshot_fun, pr_fetch_fun \\ fn _ticket -> nil end) do
    parent = self()
    monitor_name = unique_name("Monitor")

    {:ok, pid} =
      Monitor.start_link(
        name: monitor_name,
        store: store_name,
        snapshot_fun: snapshot_fun,
        pr_fetch_fun: pr_fetch_fun,
        now_fun: now_fun,
        settings_fun: fn -> settings end,
        alert_emitter: fn payload -> send(parent, {:alert, payload}) end,
        resolution_emitter: fn payload -> send(parent, {:resolution, payload}) end,
        interval_ms: 60_000,
        start_paused?: true
      )

    pid
  end

  defp start_agent_snapshot(tickets) do
    {:ok, agent} = Agent.start_link(fn -> tickets end)
    {fn _now -> Agent.get(agent, & &1) end, agent}
  end

  # Sends a tick and waits until the store records the ticket, proving the tick
  # fully processed before the test advances the clock (prevents a race where a
  # queued tick observes an already-advanced clock and sets a wrong anchor).
  defp tick_and_wait(pid, store_name, identifier) do
    send(pid, :tick)
    wait_until(fn -> Store.record(identifier, store_name) != nil end)
  end

  # Waits until the monitor has consumed the pending :tick message. Used only
  # for ticks that perform no store write (e.g. an empty snapshot), where the
  # record-based wait above has nothing to observe.
  defp wait_for_mailbox_drained(pid, attempts \\ 400) do
    case Process.info(pid, :messages) do
      {:messages, []} ->
        :ok

      _ when attempts <= 0 ->
        flunk("monitor mailbox did not drain")

      _ ->
        Process.sleep(5)
        wait_for_mailbox_drained(pid, attempts - 1)
    end
  end

  defp wait_until(fun, attempts \\ 400) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        flunk("timed out waiting for monitor state change")

      true ->
        Process.sleep(5)
        wait_until(fun, attempts - 1)
    end
  end

  defp stored(store_name, identifier), do: Store.record(identifier, store_name) || %{}

  test "an ordinary healthy ticket before the first threshold emits no alert", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    {now_fun, set_time, _} = start_clock(@t0)

    pid =
      start_monitor(store.name, now_fun, %{first_hours: 8, continuous_hours: 1}, fn _now ->
        [healthy_ticket("101")]
      end)

    tick_and_wait(pid, store.name, "101")
    refute_receive {:alert, _payload}, 100

    set_time.(hours(7.9))
    send(pid, :tick)
    wait_until(fn -> stored(store.name, "101").last_alert_at == nil end)
    refute_receive {:alert, _payload}, 100
  end

  test "fires the first advisory at the 8h boundary, and only as an advisory alert", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    {now_fun, set_time, _} = start_clock(@t0)

    pid =
      start_monitor(store.name, now_fun, %{first_hours: 8, continuous_hours: 1}, fn _now ->
        [healthy_ticket("101")]
      end)

    tick_and_wait(pid, store.name, "101")
    refute_receive {:alert, _payload}, 50

    set_time.(hours(8))
    send(pid, :tick)

    assert_receive {:alert, %{identifier: "101", evidence: evidence}}, 500
    assert evidence.age_hours == 8.0
    assert evidence.repeated? == false
    assert evidence.first_hours == 8
    refute_receive {:alert, _payload}, 50
  end

  test "repeats at the 1h cadence and does not storm", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    {now_fun, set_time, _} = start_clock(@t0)

    pid =
      start_monitor(store.name, now_fun, %{first_hours: 8, continuous_hours: 1}, fn _now ->
        [healthy_ticket("101")]
      end)

    tick_and_wait(pid, store.name, "101")
    set_time.(hours(8))
    send(pid, :tick)
    assert_receive {:alert, %{identifier: "101", evidence: %{repeated?: false}}}, 500

    # +30 minutes: not yet one cadence hour after the last alert.
    set_time.(hours(8.5))
    send(pid, :tick)
    wait_until(fn -> stored(store.name, "101").last_alert_at == hours(8) end)
    refute_receive {:alert, _payload}, 100

    # +1 hour: continuous reminder fires.
    set_time.(hours(9))
    send(pid, :tick)
    assert_receive {:alert, %{identifier: "101", evidence: %{repeated?: true}}}, 500

    # Back-to-back tick at the same clock: no storm.
    send(pid, :tick)
    wait_until(fn -> stored(store.name, "101").last_alert_at == hours(9) end)
    refute_receive {:alert, _payload}, 100
  end

  test "a daemon restart does not reset the clock or re-fire the first alert", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    {now_fun, set_time, _} = start_clock(@t0)

    pid =
      start_monitor(store.name, now_fun, %{first_hours: 8, continuous_hours: 1}, fn _now ->
        [healthy_ticket("101")]
      end)

    tick_and_wait(pid, store.name, "101")
    set_time.(hours(8))
    send(pid, :tick)
    assert_receive {:alert, %{identifier: "101"}}, 500

    # Daemon restart: stop monitor + store, boot fresh over the same state dir.
    GenServer.stop(pid)
    GenServer.stop(store.name)

    store2 = start_store(state_dir)
    {now_fun2, set_time2, _} = start_clock(hours(8))

    pid2 =
      start_monitor(store2.name, now_fun2, %{first_hours: 8, continuous_hours: 1}, fn _now ->
        [healthy_ticket("101")]
      end)

    # Same convergence age as the first alert — must NOT re-fire it.
    tick_and_wait(pid2, store2.name, "101")
    refute_receive {:alert, _payload}, 100

    # The continuous cadence resumes from the persisted last-alert time.
    set_time2.(hours(9))
    send(pid2, :tick)
    assert_receive {:alert, %{identifier: "101", evidence: %{repeated?: true}}}, 500
  end

  test "a terminal ticket cancels continuous alerts and emits one resolution", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    {now_fun, set_time, _} = start_clock(@t0)
    {snapshot_fun, snapshot_agent} = start_agent_snapshot([healthy_ticket("101")])

    pid = start_monitor(store.name, now_fun, %{first_hours: 8, continuous_hours: 1}, snapshot_fun)

    tick_and_wait(pid, store.name, "101")
    set_time.(hours(8))
    send(pid, :tick)
    assert_receive {:alert, %{identifier: "101"}}, 500

    set_time.(hours(9))

    Agent.update(snapshot_agent, fn _tickets ->
      [Map.put(healthy_ticket("101"), :terminal?, true)]
    end)

    send(pid, :tick)
    assert_receive {:resolution, %{identifier: "101"}}, 500
    wait_until(fn -> Store.record("101", store.name) == nil end)

    # Once forgotten, further ticks emit nothing.
    send(pid, :tick)
    refute_receive {:resolution, _payload}, 100
    refute_receive {:alert, _payload}, 100
  end

  test "a ticket that leaves the run scope is resolved after a grace period, not on a transient gap", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    {now_fun, set_time, _} = start_clock(@t0)
    {snapshot_fun, snapshot_agent} = start_agent_snapshot([healthy_ticket("101")])

    pid = start_monitor(store.name, now_fun, %{first_hours: 8, continuous_hours: 1}, snapshot_fun)

    tick_and_wait(pid, store.name, "101")
    set_time.(hours(8))
    send(pid, :tick)
    assert_receive {:alert, %{identifier: "101"}}, 500

    # The ticket disappears from the snapshot. A short absence (a transient gap,
    # e.g. a daemon/orchestrator restart) must not resolve it or reset the clock.
    Agent.update(snapshot_agent, fn _tickets -> [] end)
    set_time.(hours(8.5))
    send(pid, :tick)
    wait_until(fn -> stored(store.name, "101").last_seen_at == hours(8) end)
    refute_receive {:resolution, _payload}, 100
    assert Store.record("101", store.name) != nil

    # Once the absence exceeds the scope grace period, the out-of-scope ticket is
    # resolved and forgotten.
    set_time.(hours(11))
    send(pid, :tick)
    assert_receive {:resolution, %{identifier: "101"}}, 500
    wait_until(fn -> Store.record("101", store.name) == nil end)
  end

  test "a non-authoritative snapshot never forgets durable convergence state", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    {now_fun, set_time, _} = start_clock(@t0)
    {snapshot_fun, snapshot_agent} = start_agent_snapshot([healthy_ticket("101")])

    wrapped_snapshot = fn now ->
      tickets = snapshot_fun.(now)
      %{tickets: tickets, authoritative?: tickets != []}
    end

    pid = start_monitor(store.name, now_fun, %{first_hours: 8, continuous_hours: 1}, wrapped_snapshot)
    tick_and_wait(pid, store.name, "101")

    Agent.update(snapshot_agent, fn _ -> [] end)
    set_time.(hours(12))
    send(pid, :tick)
    wait_for_mailbox_drained(pid)

    refute_receive {:resolution, _payload}, 100
    assert Store.record("101", store.name).anchor_at == @t0
  end

  test "a failed PR refresh preserves the cached PR age floor", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    {now_fun, set_time, _} = start_clock(hours(7))
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    pr_fetch_fun = fn _ticket ->
      Agent.get_and_update(calls, fn
        0 -> {{:ok, %{number: 5, created_at: @t0}}, 1}
        n -> {{:error, :network}, n + 1}
      end)
    end

    pid =
      start_monitor(
        store.name,
        now_fun,
        %{first_hours: 8, continuous_hours: 1},
        fn _ -> [healthy_ticket("101")] end,
        pr_fetch_fun
      )

    tick_and_wait(pid, store.name, "101")
    set_time.(hours(8))
    send(pid, :tick)

    assert_receive {:alert, %{identifier: "101", evidence: %{age_hours: 8.0}}}, 500
    assert Store.record("101", store.name).pr.created_at == @t0
  end

  test "a worker restart (brief absence and return) does not reset the convergence clock", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    {now_fun, set_time, _} = start_clock(@t0)
    {snapshot_fun, snapshot_agent} = start_agent_snapshot([healthy_ticket("101")])

    pid = start_monitor(store.name, now_fun, %{first_hours: 8, continuous_hours: 1}, snapshot_fun)
    tick_and_wait(pid, store.name, "101")

    # A worker restart / max_turns recycle: the ticket briefly drops out of the
    # snapshot (redispatch gap) and returns, well inside the scope grace period.
    Agent.update(snapshot_agent, fn _tickets -> [] end)
    set_time.(hours(0.2))
    send(pid, :tick)
    # The empty-snapshot tick performs no store write, so wait for it to drain
    # from the monitor's mailbox before asserting nothing was resolved.
    wait_for_mailbox_drained(pid)
    refute_receive {:resolution, _payload}, 100

    Agent.update(snapshot_agent, fn _tickets -> [healthy_ticket("101")] end)
    set_time.(hours(0.5))
    send(pid, :tick)
    wait_until(fn -> stored(store.name, "101").last_seen_at == hours(0.5) end)

    # The convergence clock was not reset: at the 8h boundary the first advisory
    # still fires at the original age.
    set_time.(hours(8))
    send(pid, :tick)
    assert_receive {:alert, %{identifier: "101", evidence: %{age_hours: 8.0}}}, 500
  end

  test "multiple tickets alert independently", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    {now_fun, set_time, _} = start_clock(@t0)

    pid =
      start_monitor(store.name, now_fun, %{first_hours: 8, continuous_hours: 1}, fn _now ->
        [healthy_ticket("101"), healthy_ticket("202")]
      end)

    send(pid, :tick)
    wait_until(fn -> Store.record("101", store.name) != nil and Store.record("202", store.name) != nil end)
    set_time.(hours(8))
    send(pid, :tick)

    assert_receive {:alert, %{identifier: "101"}}, 500
    assert_receive {:alert, %{identifier: "202"}}, 500
  end

  test "an already-open PR acts as the age floor so a fresh monitor cannot hide it", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    # The monitor boots at t+20h; the open PR was created at @t0.
    {now_fun, _set_time, _} = start_clock(hours(20))

    pr_fetch_fun = fn _ticket ->
      %{number: 5, created_at: @t0, pushed_at: @t0, mergeable_state: "clean", ci_state: nil}
    end

    pid =
      start_monitor(
        store.name,
        now_fun,
        %{first_hours: 8, continuous_hours: 1},
        fn _now ->
          [healthy_ticket("101")]
        end,
        pr_fetch_fun
      )

    send(pid, :tick)

    assert_receive {:alert, %{identifier: "101", evidence: %{age_hours: age}}}, 500
    assert age == 20.0
  end

  test "zero first-hours disables alerts and resolves a previously-active advisory", %{} do
    state_dir = tmp_state_dir()
    store = start_store(state_dir)
    {now_fun, set_time, _} = start_clock(@t0)
    {snapshot_fun, _agent} = start_agent_snapshot([healthy_ticket("101")])

    pid = start_monitor(store.name, now_fun, %{first_hours: 8, continuous_hours: 1}, snapshot_fun)
    tick_and_wait(pid, store.name, "101")
    set_time.(hours(8))
    send(pid, :tick)
    assert_receive {:alert, %{identifier: "101"}}, 500

    GenServer.stop(pid)

    # Reconfigured with the alert disabled: the active advisory is resolved and
    # no new alerts fire.
    pid2 = start_monitor(store.name, now_fun, %{first_hours: 0, continuous_hours: 0}, snapshot_fun)
    send(pid2, :tick)

    assert_receive {:resolution, %{identifier: "101"}}, 500
    refute_receive {:alert, _payload}, 100
  end

  defp tmp_state_dir do
    dir = Path.join(System.tmp_dir!(), "takeover_monitor_#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(dir)
    # unique_integer values are reused across VM boots (see test_helper.exs), so
    # a leaked dir from a previous run can collide with a fresh one and the store
    # would load stale convergence state. Always clean the dir up.
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
