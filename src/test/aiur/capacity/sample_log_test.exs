defmodule Aiur.Capacity.SampleLogTest do
  use ExUnit.Case, async: true

  alias Aiur.Capacity.SampleLog
  alias Aiur.ProviderMeterRefresh

  @now ~U[2026-11-09 12:00:00Z]

  test "one row per metered account plus each unmetered provider, unknown figures as null" do
    inputs = %{
      accounts: %{
        {"claude", "default"} => %{reading: %{windows: [%{window: "seven_day", used_percent: 70}]}, observed_at: ~U[2026-11-09 11:59:00Z], freshness: :fresh},
        {"claude", "work"} => %{reading: nil, observed_at: @now, freshness: :unavailable}
      },
      providers: %{
        claude: %{freshness: :fresh, windows: %{"x" => %{remaining_percent: 99}}},
        codex: %{freshness: :fresh, age_seconds: 40, observed_at: ~U[2026-11-09 11:59:20Z], windows: %{"primary" => %{remaining_percent: 62}, "secondary" => %{remaining_percent: 80}}},
        openrouter: %{freshness: :unknown, windows: %{"credits" => %{remaining_percent: 10}}}
      },
      running: %{{"claude", "default"} => 2},
      policy: %{{"claude", "default"} => %{reserve_percent: 30, projected_percent: 27, open_holds: 2}}
    }

    sample = SampleLog.sample(inputs, @now)
    rows = Map.new(sample.accounts, &{{&1.backend, &1.account}, &1})

    assert Map.keys(rows) |> Enum.sort() == [{"claude", "default"}, {"claude", "work"}, {"codex", nil}, {"openrouter", nil}]

    assert %{remaining_percent: 30, projected_percent: 27, reserve_percent: 30, open_holds: 2, running: 2, freshness: :fresh, age_ms: 60_000} =
             rows[{"claude", "default"}]

    assert %{remaining_percent: nil, reserve_percent: nil, open_holds: nil, running: 0, freshness: :unavailable} = rows[{"claude", "work"}]
    assert %{remaining_percent: 62, age_ms: 40_000} = rows[{"codex", nil}]
    # An unknown provider never shows its stale window as a figure.
    assert %{remaining_percent: nil, freshness: :unknown} = rows[{"openrouter", nil}]
    assert sample.at == "2026-11-09T12:00:00Z"
  end

  @tag :tmp_dir
  test "append writes one JSON line per sample under a missing directory", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "run", "log", "capacity.ndjson"])

    :ok = SampleLog.append(path, SampleLog.sample(%{}, @now))
    :ok = SampleLog.append(path, SampleLog.sample(%{}, ~U[2026-11-09 12:05:00Z]))

    assert [first, second] = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert first["at"] == "2026-11-09T12:00:00Z" and first["accounts"] == [] and first["schema"] == 1
    assert second["at"] == "2026-11-09T12:05:00Z"
  end

  test "the refresh tick samples even when nothing is observed" do
    test = self()

    {:ok, _pid} =
      ProviderMeterRefresh.start_link(
        name: nil,
        observer: fn target -> send(test, {:observed, target}) end,
        sampler: fn -> send(test, :sampled) end,
        agents_running_fun: fn -> false end,
        headroom_fun: fn -> false end,
        interval_fun: fn -> 20 end,
        baseline_delay_ms: :never
      )

    assert_receive :sampled, 1_000
    assert_receive :sampled, 1_000
    refute_received {:observed, _target}
  end
end
