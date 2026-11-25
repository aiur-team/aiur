defmodule Aiur.ProviderMeterRefresh.ResetTest do
  # After a provider's window reset, an idle daemon kept reporting it exhausted
  # until an operator restarted every instance: nothing re-read a provider that
  # nobody was watching. The refresher now re-reads it at the recorded reset,
  # with backoff until the new window shows, and periodically while exhausted.
  use ExUnit.Case, async: true

  alias Aiur.ProviderMeterRefresh
  alias Aiur.ProviderMeterRefresh.Schedule

  setup do
    {:ok, now: DateTime.utc_now() |> DateTime.truncate(:second)}
  end

  describe "an idle refresher" do
    test "re-reads an exhausted provider whose reset has passed on the next tick, then waits for the next reset", %{now: now} do
      next_reset = DateTime.add(now, 7 * 86_400, :second)
      views = start_views(%{codex: view(DateTime.add(now, -16 * 3600, :second), 100, DateTime.add(now, -3600, :second))})
      test = self()

      observer = fn target ->
        send(test, {:observed, target})
        Agent.update(views, fn _ -> %{codex: view(now, 3, next_reset)} end)
      end

      pid = start_refresh(views, fn -> now end, observer: observer)

      assert_receive {:observed, :codex}, 1_000
      refute_receive {:observed, _target}, 300
      assert ProviderMeterRefresh.next_checks(pid) == %{codex: DateTime.add(next_reset, 60, :second)}
    end

    test "retries with backoff while the provider still reports the old window", %{now: now} do
      {:ok, clock} = Agent.start_link(fn -> now end)
      views = start_views(%{codex: view(DateTime.add(now, -16 * 3600, :second), 100, DateTime.add(now, -60, :second))})
      pid = start_refresh(views, fn -> Agent.get(clock, & &1) end)

      assert_receive {:observed, :codex}, 1_000
      refute_receive {:observed, _target}, 300
      assert ProviderMeterRefresh.next_checks(pid) == %{codex: DateTime.add(now, 60, :second)}

      Agent.update(clock, &DateTime.add(&1, 61, :second))
      assert_receive {:observed, :codex}, 1_000
    end

    test "leaves a provider alone that is neither exhausted nor past a reset", %{now: now} do
      views = start_views(%{claude: view(DateTime.add(now, -3600, :second), 40, DateTime.add(now, 3600, :second))})
      pid = start_refresh(views, fn -> now end)

      refute_receive {:observed, _target}, 300
      assert ProviderMeterRefresh.next_checks(pid) == %{claude: DateTime.add(now, 3660, :second)}
    end
  end

  describe "schedule" do
    test "an exhausted window with no recorded reset is re-read every 15 minutes", %{now: now} do
      observed = DateTime.add(now, -5 * 60, :second)
      checks = Schedule.next_checks(%{codex: view(observed, 100, nil)}, now, %{})

      assert checks == %{codex: DateTime.add(observed, 15 * 60, :second)}
      assert Schedule.due(checks, now) == []
      assert Schedule.due(checks, DateTime.add(observed, 15 * 60, :second)) == [:codex]
    end

    test "a reading taken after the reset no longer waits for it", %{now: now} do
      reset = DateTime.add(now, -600, :second)

      assert Schedule.awaiting_reset?(view(DateTime.add(reset, -1, :second), 100, reset), now)
      refute Schedule.awaiting_reset?(view(reset, 100, reset), now)
    end

    test "backoff doubles from one minute and stops growing at 15", %{now: now} do
      waiting = %{codex: view(DateTime.add(now, -86_400, :second), 100, DateTime.add(now, -3600, :second))}

      for {count, seconds} <- [{1, 60}, {2, 120}, {3, 240}, {5, 900}, {9, 900}] do
        assert Schedule.next_checks(waiting, now, %{codex: %{at: now, count: count}}) == %{codex: DateTime.add(now, seconds, :second)}
      end
    end
  end

  describe "projected windows" do
    # `aiur usage` and the dashboard showed a passed window's 100% as current.
    test "a window whose reset has passed reads as unknown; one still to reset keeps its view's freshness", %{now: now} do
      windows = %{
        "primary" => %{used_percent: 100, resets_at: DateTime.add(now, -60, :second)},
        "weekly" => %{used_percent: 40, resets_at: DateTime.add(now, 3600, :second)}
      }

      projected = Aiur.ProviderMeterProjection.Windows.project(windows, :stale, now)

      assert projected["primary"].freshness == :unknown
      assert projected["weekly"].freshness == :stale
    end
  end

  defp view(observed_at, used_percent, resets_at) do
    %{observed_at: observed_at, windows: %{"primary" => %{used_percent: used_percent, resets_at: resets_at}}}
  end

  defp start_views(views) do
    {:ok, agent} = Agent.start_link(fn -> views end)
    agent
  end

  defp start_refresh(views, wall_clock, opts \\ []) do
    test = self()

    {:ok, pid} =
      ProviderMeterRefresh.start_link(
        name: nil,
        observer: Keyword.get(opts, :observer, fn target -> send(test, {:observed, target}) end),
        agents_running_fun: fn -> false end,
        headroom_fun: fn -> false end,
        interval_fun: fn -> 50 end,
        baseline_delay_ms: :never,
        snapshot_fun: fn -> Agent.get(views, & &1) end,
        wall_clock: wall_clock
      )

    pid
  end
end
