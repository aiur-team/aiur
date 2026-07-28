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

  # Claude is one cached HTTPS read of the account usage endpoint, independent
  # of any agent, so it keeps refreshing on an idle daemon. Codex means opening
  # an app-server session — real work — and a fleet consuming nothing cannot
  # have moved its own usage, so it is not re-observed while idle.
  test "an idle fleet keeps refreshing Claude but stops re-observing Codex" do
    start_refresh(agents_running?: false, baseline_delay_ms: 10, interval_ms: 20)

    assert_receive {:observed, :all}, 1_000

    assert_receive {:observed, :claude}, 1_000
    assert_receive {:observed, :claude}, 1_000
    refute_receive {:observed, :all}, 100
  end

  test "refreshes continue while agents are running" do
    start_refresh(agents_running?: true, baseline_delay_ms: 10, interval_ms: 20)

    assert_receive {:observed, :all}, 1_000
    assert_receive {:observed, :all}, 1_000
    assert_receive {:observed, :all}, 1_000
  end

  test "an explicit refresh observes regardless of agent activity" do
    pid = start_refresh(agents_running?: false, baseline_delay_ms: :never, interval_ms: 60_000)

    ProviderMeterRefresh.refresh_now(pid)

    assert_receive {:observed, :all}, 1_000
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
    # ...but no refresh follows, because the orchestrator answered "unavailable".
    refute_receive {:observed, :all}, 300
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

  defp start_refresh(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, 60_000)

    {:ok, pid} =
      ProviderMeterRefresh.start_link(
        name: nil,
        observer: Keyword.get(opts, :observer, collector()),
        agents_running_fun: fn -> Keyword.fetch!(opts, :agents_running?) end,
        interval_fun: fn -> interval_ms end,
        baseline_delay_ms: Keyword.get(opts, :baseline_delay_ms, 10)
      )

    pid
  end
end
