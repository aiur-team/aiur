defmodule Aiur.ProviderMeterRefreshTest do
  use ExUnit.Case, async: true

  alias Aiur.ProviderMeterRefresh

  defp collector do
    test = self()
    fn target -> send(test, {:observed, target}) end
  end

  test "a baseline observation runs after boot even with no agents running" do
    start_refresh(agents_running?: false, baseline_delay_ms: 10)

    assert_receive {:observed, :all}, 1_000
  end

  # Both providers refresh while someone is watching, whether or not the fleet
  # is busy: an operator looking at a meter wants both numbers, and an idle
  # daemon is exactly when the question "how much is left?" gets asked.
  test "an idle fleet still refreshes both providers while watched" do
    pid = start_refresh(agents_running?: false, baseline_delay_ms: 10, interval_ms: 20)
    ProviderMeterRefresh.watching_started(pid)

    assert_receive {:observed, :all}, 1_000
    assert_receive {:observed, :all}, 1_000
    assert_receive {:observed, :all}, 1_000
  end

  test "refreshes continue while agents are running" do
    pid = start_refresh(agents_running?: true, baseline_delay_ms: 10, interval_ms: 20)
    ProviderMeterRefresh.watching_started(pid)

    assert_receive {:observed, :all}, 1_000
    assert_receive {:observed, :all}, 1_000
    assert_receive {:observed, :all}, 1_000
  end

  test "an explicit refresh observes regardless of agent activity" do
    pid = start_refresh(agents_running?: false, baseline_delay_ms: :never, interval_ms: 60_000)

    ProviderMeterRefresh.refresh_now(pid)

    assert_receive {:observed, :all}, 1_000
  end

  test "a slow probe never blocks the cadence server and overlapping requests coalesce" do
    test = self()

    pid =
      start_refresh(
        agents_running?: false,
        baseline_delay_ms: :never,
        interval_ms: 60_000,
        observer: fn target ->
          send(test, {:probe_started, target, self()})
          receive do: (:release -> :ok)
        end
      )

    ProviderMeterRefresh.refresh_now(pid)
    assert_receive {:probe_started, :all, probe_pid}, 1_000

    assert %{probe_ref: probe_ref} = :sys.get_state(pid, 500)
    assert is_reference(probe_ref)

    ProviderMeterRefresh.refresh_now(pid)
    refute_receive {:probe_started, :all, _other_pid}, 100

    send(probe_pid, :release)
  end

  # A provider being unreachable is expected, not fatal: the retained
  # observation keeps displaying with its true age.
  test "an observer that raises never takes the scheduler down" do
    test = self()

    pid =
      start_refresh(
        agents_running?: true,
        baseline_delay_ms: 10,
        interval_ms: 20,
        observer: fn _target ->
          send(test, :observed_boom)
          raise "provider unreachable"
        end
      )

    ProviderMeterRefresh.watching_started(pid)

    assert_receive :observed_boom, 1_000
    assert_receive :observed_boom, 1_000
    assert Process.alive?(pid)
  end

  test "unrelated messages are ignored" do
    pid = start_refresh(agents_running?: false, baseline_delay_ms: :never, interval_ms: 60_000)

    send(pid, :something_else)

    refute_receive {:observed, _target}, 100
    assert Process.alive?(pid)
  end

  # `baseline_delay_ms: :never` is how a caller opts out of the boot probe: it
  # must schedule nothing, without breaking the explicit-refresh path.
  test "the baseline can be disabled outright" do
    pid = start_refresh(agents_running?: true, baseline_delay_ms: :never, interval_ms: 60_000)

    refute_receive {:observed, :all}, 200

    ProviderMeterRefresh.refresh_now(pid)
    assert_receive {:observed, :all}, 1_000
  end

  # With no injected interval the scheduler resolves one from config, falling
  # back to a real cadence rather than crashing or scheduling immediately.
  test "a missing injected interval resolves from config" do
    test = self()

    {:ok, pid} =
      ProviderMeterRefresh.start_link(
        name: nil,
        observer: fn target -> send(test, {:observed, target}) end,
        agents_running_fun: fn -> false end,
        baseline_delay_ms: 10
      )

    assert_receive {:observed, :all}, 1_000
    assert Process.alive?(pid)
  end

  # With no injected agents-running probe it asks the orchestrator, which is not
  # running here. That must resolve to "no agents" rather than crashing the
  # scheduler — an unavailable orchestrator is a normal state at boot.
  test "an unavailable orchestrator resolves to no-agents rather than crashing" do
    test = self()

    {:ok, pid} =
      ProviderMeterRefresh.start_link(
        name: nil,
        observer: fn target -> send(test, {:observed, target}) end,
        interval_fun: fn -> 30 end,
        baseline_delay_ms: 10
      )

    # Baseline still fires (it ignores agent state by design)...
    assert_receive {:observed, :all}, 1_000

    # ...and with someone watching, refreshes keep running even though the
    # orchestrator is unavailable — that answer gates nothing any more, it just
    # must not crash the scheduler.
    ProviderMeterRefresh.watching_started(pid)
    assert_receive {:observed, :all}, 1_000
    assert Process.alive?(pid)
  end

  test "it is supervisable, and the default-arity refresh targets the running scheduler" do
    spec = ProviderMeterRefresh.child_spec([])

    assert spec.id == ProviderMeterRefresh
    assert spec.restart == :permanent

    # Cast to the app-supervised scheduler: it must accept the message without
    # the caller naming a server.
    assert ProviderMeterRefresh.refresh_now() == :ok
  end

  describe "watch gating" do
    # Polling exists to keep a surface current. With nobody looking, it is pure
    # cost against a rate-limited endpoint.
    test "no refresh happens when nobody is watching" do
      start_refresh(agents_running?: true, baseline_delay_ms: :never, interval_ms: 20)

      refute_receive {:observed, _target}, 300
    end

    test "a watcher gaining focus is observed immediately, then on the interval" do
      pid = start_refresh(agents_running?: true, baseline_delay_ms: :never, interval_ms: 30)

      ProviderMeterRefresh.watching_started(pid)

      # Immediate, rather than waiting out the interval for a stale number.
      assert_receive {:observed, :all}, 500
      assert_receive {:observed, :all}, 1_000
    end

    test "polling continues through the grace period, then stops" do
      pid = start_refresh(agents_running?: true, baseline_delay_ms: :never, interval_ms: 20, grace_ms: 300)

      ProviderMeterRefresh.watching_started(pid)
      assert_receive {:observed, :all}, 500

      ProviderMeterRefresh.watching_stopped(pid)

      # Still inside the grace window: a glance away must not cost a stale meter.
      assert_receive {:observed, :all}, 500

      # Past it: an abandoned tab stops costing requests.
      Process.sleep(400)
      flush()
      refute_receive {:observed, _target}, 300
    end

    # A closed tab never sends a tidy goodbye, so the watcher must withdraw
    # itself when its process dies.
    test "a watcher that dies stops counting as watching" do
      pid = start_refresh(agents_running?: true, baseline_delay_ms: :never, interval_ms: 20, grace_ms: 0)
      test_pid = self()

      watcher =
        spawn(fn ->
          ProviderMeterRefresh.watching_started(pid)
          send(test_pid, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered, 1_000
      assert_receive {:observed, :all}, 1_000

      Process.exit(watcher, :kill)
      Process.sleep(150)
      flush()

      refute_receive {:observed, _target}, 300
    end

    test "several watchers hold polling open until the last one leaves" do
      pid = start_refresh(agents_running?: true, baseline_delay_ms: :never, interval_ms: 20, grace_ms: 0)
      test_pid = self()

      other =
        spawn(fn ->
          ProviderMeterRefresh.watching_started(pid)
          send(test_pid, :other_registered)
          receive do: (:leave -> ProviderMeterRefresh.watching_stopped(pid))
          send(test_pid, :other_left)
          Process.sleep(:infinity)
        end)

      assert_receive :other_registered, 1_000
      ProviderMeterRefresh.watching_started(pid)
      assert_receive {:observed, :all}, 1_000

      # One leaves; the other is still looking, so polling continues.
      ProviderMeterRefresh.watching_stopped(pid)
      assert_receive {:observed, :all}, 1_000

      send(other, :leave)
      assert_receive :other_left, 1_000
      Process.sleep(100)
      flush()

      refute_receive {:observed, _target}, 300
    end
  end

  defp flush do
    receive do
      {:observed, _target} -> flush()
    after
      0 -> :ok
    end
  end

  defp start_refresh(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, 60_000)

    {:ok, pid} =
      ProviderMeterRefresh.start_link(
        name: nil,
        observer: Keyword.get(opts, :observer, collector()),
        agents_running_fun: fn -> Keyword.fetch!(opts, :agents_running?) end,
        interval_fun: fn -> interval_ms end,
        baseline_delay_ms: Keyword.get(opts, :baseline_delay_ms, 10),
        grace_ms: Keyword.get(opts, :grace_ms, 60_000)
      )

    pid
  end
end
