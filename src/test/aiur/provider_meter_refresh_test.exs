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

  # Observing costs a provider session, and a fleet consuming nothing cannot
  # have moved its own usage.
  test "no refresh happens while no agents are running" do
    start_refresh(agents_running?: false, baseline_delay_ms: 10, interval_ms: 20)

    assert_receive {:observed, :all}, 1_000
    refute_receive {:observed, :all}, 200
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
