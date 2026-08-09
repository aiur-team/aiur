defmodule Aiur.ProviderMeterWatchTest do
  @moduledoc """
  The dashboard reports focus so provider usage is only polled while someone is
  looking. The gating itself is covered in `Aiur.ProviderMeterRefreshTest`; this
  pins the seam between them — that the events the client pushes are the ones
  the scheduler answers to, and that a registration survives being made from a
  LiveView-like process that later dies.
  """

  use ExUnit.Case, async: true

  alias Aiur.ProviderMeterRefresh

  setup do
    test = self()

    {:ok, pid} =
      ProviderMeterRefresh.start_link(
        name: nil,
        observer: fn target -> send(test, {:observed, target}) end,
        agents_running_fun: fn -> true end,
        interval_fun: fn -> 25 end,
        baseline_delay_ms: :never,
        grace_ms: 0
      )

    %{refresh: pid}
  end

  test "a watcher registered from another process gates polling for it", %{refresh: refresh} do
    test = self()

    watcher =
      spawn(fn ->
        ProviderMeterRefresh.watching_started(refresh)
        send(test, :watching)
        Process.sleep(:infinity)
      end)

    assert_receive :watching, 1_000
    assert_receive {:observed, :all}, 1_000

    # The tab goes away without a goodbye; polling must stop on its own.
    Process.exit(watcher, :kill)
    Process.sleep(120)
    flush()

    refute_receive {:observed, _target}, 200
  end

  test "focus is idempotent — repeated starts do not double-register", %{refresh: refresh} do
    ProviderMeterRefresh.watching_started(refresh)
    ProviderMeterRefresh.watching_started(refresh)
    assert_receive {:observed, :all}, 1_000
    flush()

    # One stop is enough to withdraw, even after several starts. Otherwise a
    # tab that reported focus twice could never stop polling.
    ProviderMeterRefresh.watching_stopped(refresh)
    Process.sleep(120)
    flush()

    refute_receive {:observed, _target}, 200
  end

  test "an unknown stop is harmless", %{refresh: refresh} do
    ProviderMeterRefresh.watching_stopped(refresh)

    assert Process.alive?(refresh)
    refute_receive {:observed, _target}, 200
  end

  defp flush do
    receive do
      {:observed, _target} -> flush()
    after
      0 -> :ok
    end
  end
end
