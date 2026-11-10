defmodule Aiur.Capacity.SampleLogTest do
  use ExUnit.Case, async: true

  alias Aiur.Capacity.{Ledger, SampleLog}
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
      capacity_policy: %{
        sources: %{
          "claude" => %{reserve: %{percent: 25, accounts: ["default"]}, limits: %{daily_usd: nil}},
          "openrouter" => %{reserve: %{percent: 0, accounts: :all}, limits: %{daily_usd: 5, weekly_usd: nil}}
        },
        limits: %{monthly_usd: 100}
      },
      ledger: ledger()
    }

    sample = SampleLog.sample(inputs, @now)
    rows = Map.new(sample.accounts, &{{&1.backend, &1.account}, &1})

    assert Map.keys(rows) |> Enum.sort() == [{"claude", "default"}, {"claude", "work"}, {"codex", nil}, {"openrouter", nil}]

    # 30% read at 11:59, minus the 4% hold created after it; the hold folded before it no longer counts.
    assert %{remaining_percent: 30, projected_percent: 26, reserve_percent: 25, open_holds: 1, running: 2, freshness: :fresh, age_ms: 60_000} =
             rows[{"claude", "default"}]

    # Not on the reserve list: reserve 0, not unknown. No reading: no projection.
    assert %{remaining_percent: nil, projected_percent: nil, reserve_percent: 0, open_holds: 0, running: 0, freshness: :unavailable} = rows[{"claude", "work"}]
    assert %{remaining_percent: 62, age_ms: 40_000, reserve_percent: 0} = rows[{"codex", nil}]
    # An unknown provider never shows its stale window as a figure.
    assert %{remaining_percent: nil, freshness: :unknown} = rows[{"openrouter", nil}]
    assert sample.at == "2026-11-09T12:00:00Z"

    # Every limited period, with spend unknown rather than zero.
    assert sample.sources == [
             %{backend: "openrouter", period: :daily_usd, period_start: "2026-11-09", limit_usd: 5, spend_usd: nil},
             %{backend: "global", period: :monthly_usd, period_start: "2026-11-01", limit_usd: 100, spend_usd: nil}
           ]
  end

  test "without a policy or ledger the reserve, holds and projection are unknown" do
    inputs = %{accounts: %{{"claude", "default"} => %{reading: %{windows: [%{window: "five_hour", used_percent: 10}]}, observed_at: @now, freshness: :fresh}}}

    assert %{accounts: [%{remaining_percent: 90, projected_percent: nil, reserve_percent: nil, open_holds: nil}], sources: []} = SampleLog.sample(inputs, @now)
  end

  test "an unknown hold estimate on a reserved account makes the projection unknown" do
    ledger = Ledger.hold(Ledger.new(), %{ticket: "x", backend: "claude", account: "default", kind: :window, estimate: :unknown, rate: nil, created_at: @now})

    inputs = %{
      accounts: %{{"claude", "default"} => %{reading: %{windows: [%{window: "five_hour", used_percent: 10}]}, observed_at: ~U[2026-11-09 11:00:00Z], freshness: :fresh}},
      capacity_policy: %{sources: %{"claude" => %{reserve: %{percent: 20, accounts: :all}}}},
      ledger: ledger
    }

    assert %{accounts: [%{remaining_percent: 90, projected_percent: nil, open_holds: 1}]} = SampleLog.sample(inputs, @now)
  end

  defp ledger do
    hold = %{backend: "claude", account: "default", kind: :window, rate: 4}

    Ledger.new()
    |> Ledger.hold(Map.merge(hold, %{ticket: "old", estimate: 9, created_at: ~U[2026-11-09 11:00:00Z]}))
    |> Ledger.observe_reading("claude", "default", %{used_percent: 70, observed_at: ~U[2026-11-09 11:59:00Z]})
    |> Ledger.hold(Map.merge(hold, %{ticket: "new", estimate: 4, created_at: ~U[2026-11-09 11:59:30Z]}))
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

  @tag :tmp_dir
  test "prune drops the oldest samples past the age and size bounds and keeps the newest", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "capacity.ndjson")
    day = fn n -> DateTime.add(@now, n * 86_400, :second) end
    days = fn -> path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1)["at"]) end
    for n <- 0..39, do: :ok = SampleLog.append(path, SampleLog.sample(%{}, day.(n)))

    # Within both bounds: untouched.
    :ok = SampleLog.prune(path, max_age_days: 60, max_bytes: 1_000_000, now: day.(39))
    assert length(days.()) == 40

    :ok = SampleLog.prune(path, max_age_days: 30, max_bytes: 1_000_000, now: day.(39))
    assert days.() == Enum.map(9..39, &DateTime.to_iso8601(day.(&1)))

    line_bytes = path |> File.read!() |> String.split("\n", trim: true) |> hd() |> byte_size() |> Kernel.+(1)
    :ok = SampleLog.prune(path, max_age_days: 30, max_bytes: line_bytes * 8, now: day.(39))
    assert days.() == Enum.map(34..39, &DateTime.to_iso8601(day.(&1)))
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
