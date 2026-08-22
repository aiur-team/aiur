defmodule AiurWeb.OperatorControlCenter.Analytics.ChartsTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.Analytics.{Charts, Presenter, Styles}

  @t0 1_000_000

  defp sample(actor, type, ts, cpu, rss) do
    %{
      "cpu_percent" => cpu,
      "rss_bytes" => rss,
      actor: actor,
      actor_type: type,
      timestamp_ms: ts,
      availability: "measured"
    }
  end

  defp profile(mean, max, rss_max, count) do
    %{
      "cpu_percent" => %{count: count, mean: mean, max: max, min: 0.0, median: mean, p95: max},
      "rss_bytes" => %{count: count, mean: rss_max, max: rss_max, min: 0.0, median: rss_max, p95: rss_max}
    }
  end

  defp model do
    times = for i <- 0..10, do: @t0 + i * 60_000

    dataset = %{
      actors: %{
        "_daemon" => %{samples: Enum.map(times, &sample("_daemon", "daemon", &1, 30.0, 1_000_000)), profile: profile(30.0, 40.0, 1_000_000, 11)},
        "ticket:5" => %{samples: Enum.map(times, &sample("ticket:5", "agent", &1, 50.0, 2_000_000)), profile: profile(50.0, 120.0, 2_000_000, 11)},
        "ticket:6" => %{samples: Enum.map(times, &sample("ticket:6", "agent", &1, 20.0, 1_500_000)), profile: profile(20.0, 60.0, 1_600_000, 11)}
      },
      tickets: %{
        "5" => %{
          intervals: [
            %{phase: "dispatch", status: "point", start_ms: @t0, end_ms: nil},
            %{phase: "implement", status: "measured", start_ms: @t0 + 60_000, end_ms: @t0 + 360_000},
            %{phase: "pr_merged", status: "point", start_ms: @t0 + 480_000, end_ms: nil}
          ]
        },
        "6" => %{
          intervals: [
            %{phase: "dispatch", status: "point", start_ms: @t0 + 30_000, end_ms: nil},
            %{phase: "rework_start", status: "point", start_ms: @t0 + 540_000, end_ms: nil}
          ]
        }
      },
      provenance: %{time_range: %{start: iso(@t0 - 600_000), end: iso(@t0 + 1_800_000)}}
    }

    Presenter.model(dataset, cap: 4, cores: 4, host_mem_bytes: 4_000_000_000, buckets: 12)
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  test "cpu_stack renders a stacked SVG with the machine ceiling and unit layers" do
    m = model()
    svg = Charts.cpu_stack(m, MapSet.new(m.actors, & &1.key))
    assert svg =~ "<svg"
    assert svg =~ "machine ceiling"
    assert svg =~ "<path"
    assert svg =~ "var(--an-s1)"
  end

  test "cpu_stack with no units selected still renders the baseline" do
    m = model()
    assert Charts.cpu_stack(m, MapSet.new()) =~ "<svg"
  end

  test "concurrency renders the cap line and a wasted-capacity band" do
    m = model()
    svg = Charts.concurrency(m)
    assert svg =~ "cap 4"
    assert svg =~ "var(--blocking)"
    assert svg =~ "<path"
  end

  test "fleet pressure renders aligned count, wait, and source-state lanes" do
    series = [
      %{
        t_ms: @t0,
        pressure_state: :measured,
        fleet_agents_occupied: 13,
        fleet_agents_effective: 12,
        build_gate_capacity: 3,
        build_gate_active: 2,
        build_gate_queued: 8,
        build_queue_oldest_wait_seconds: 189
      },
      %{t_ms: @t0 + 60_000, pressure_state: :degraded_build}
    ]

    svg = Charts.fleet_pressure(%{model() | series: series})
    assert svg =~ "Whole-host fleet-wide occupancy and build pressure"
    assert svg =~ "occupied agents"
    assert svg =~ "build capacity"
    assert svg =~ "oldest live wait"
    assert svg =~ "degraded_build"
    assert svg =~ ~s(data-time-brush="true")
  end

  test "memory renders against the host ceiling" do
    assert Charts.memory(model()) =~ "host"
  end

  test "gantt renders one labelled row per ticket" do
    svg = Charts.gantt(model())
    assert svg =~ "<rect"
    assert svg =~ "#5"
    assert svg =~ "#6"
  end

  test "gantt does not render work before a ticket reaches its work phase" do
    svg =
      Charts.gantt(%{
        window: %{start_ms: 1_000, end_ms: 2_000},
        tickets: [%{id: 5, start_ms: 1_000, work_ms: 3_000, end_ms: 4_000, status: :merged}]
      })

    assert svg =~ "#5"
    refute svg =~ ~s|fill="var(--good)"|
  end

  test "cost renders ranked bars for every sort metric" do
    m = model()
    sel = MapSet.new(m.actors, & &1.key)

    for sort <- [:cpu, :peakcpu, :mem] do
      svg = Charts.cost(m, sel, sort)
      assert svg =~ "<rect"
      assert svg =~ "#5"
    end
  end

  test "burnup renders the scope line" do
    assert Charts.burnup(model()) =~ "scope"
  end

  test "analytics styling and chart guides use no dashed treatment" do
    m = model()

    refute Styles.css() =~ "dashed"

    for chart <- [
          Charts.cpu_stack(m, MapSet.new(m.actors, & &1.key)),
          Charts.concurrency(m),
          Charts.fleet_pressure(m),
          Charts.memory(m),
          Charts.burnup(m)
        ] do
      refute chart =~ "stroke-dasharray"
    end
  end

  test "a shared time domain crops every time chart while preserving the elapsed axis origin" do
    m = model()
    domain = {@t0 + 120_000, @t0 + 360_000}
    zoomed = Charts.with_time_domain(m, domain)

    assert zoomed.window.start_ms == elem(domain, 0)
    assert zoomed.window.end_ms == elem(domain, 1)
    assert zoomed.window.axis_origin_ms == m.window.start_ms
    timestamps = Enum.map(zoomed.series, & &1.t_ms)
    assert Enum.count(timestamps, &(&1 < elem(domain, 0))) <= 1
    assert Enum.count(timestamps, &(&1 > elem(domain, 1))) <= 1
    assert Charts.time_domain_label(zoomed, domain) == "3m–7m"

    for chart <- [
          Charts.gantt(zoomed),
          Charts.cpu_stack(zoomed, MapSet.new(m.actors, & &1.key)),
          Charts.concurrency(zoomed),
          Charts.fleet_pressure(zoomed),
          Charts.memory(zoomed),
          Charts.burnup(zoomed)
        ] do
      assert chart =~ "data-time-brush=\"true\""
      assert chart =~ "3m"
    end

    assert Charts.concurrency(m) =~ "now"
  end

  test "a domain strictly between two samples keeps the boundary samples so lines reach the plot edges" do
    m = model()
    [a, b | _] = Enum.drop(m.series, 3)
    gap = b.t_ms - a.t_ms
    domain = {a.t_ms + div(gap, 3), b.t_ms - div(gap, 3)}
    zoomed = Charts.with_time_domain(m, domain)

    assert zoomed.window.start_ms == elem(domain, 0)
    assert Enum.map(zoomed.series, & &1.t_ms) == [a.t_ms, b.t_ms]
  end

  test "rejects a degenerate time domain" do
    assert Charts.with_time_domain(model(), {@t0 + 60_000, @t0 + 60_001}).window == model().window
  end

  test "normalizes reversed hook values to the available axis and rejects malformed domains" do
    m = model()

    assert Charts.normalize_time_domain(m, {"1600000", "400000"}) == nil
    assert Charts.normalize_time_domain(m, {@t0 + 360_000.0, @t0 + 120_000.0}) == {@t0 + 120_000, @t0 + 360_000}
    assert Charts.normalize_time_domain(m, {"not-a-time", @t0 + 120_000}) == nil
    assert Charts.normalize_time_domain(m, :not_a_domain) == nil
    assert Charts.with_time_domain(m, nil) == m
  end

  test "omits the now marker when the shared domain no longer contains it" do
    m = update_in(model().window, &Map.put(&1, :now_ms, @t0 + 900_000))

    refute Charts.cpu_stack(m, MapSet.new(m.actors, & &1.key)) =~ ">now<"
  end

  test "complexity breakdown renders counts, average wall-clock, and em dashes" do
    m =
      Map.put(model(), :complexity_breakdown, [
        %{tier: 1, count: 2, average_wall_clock_ms: 90_000},
        %{tier: 2, count: 0, average_wall_clock_ms: nil},
        %{tier: 3, count: 1, average_wall_clock_ms: 3_600_000},
        %{tier: 4, count: 0, average_wall_clock_ms: nil},
        %{tier: 5, count: 0, average_wall_clock_ms: nil}
      ])

    svg = Charts.complexity_breakdown(m)
    assert svg =~ "Complexity breakdown"
    assert svg =~ "Complexity 1: 2 tickets"
    assert svg =~ "1m"
    assert svg =~ "—"
    assert svg =~ "var(--an-s1)"
    refute svg =~ "#3987e5"
  end
end
