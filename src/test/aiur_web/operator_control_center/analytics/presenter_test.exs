defmodule AiurWeb.OperatorControlCenter.Analytics.PresenterTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  @t0 1_000_000

  defp sample(actor, actor_type, ts, cpu, rss) do
    %{
      "cpu_percent" => cpu,
      "rss_bytes" => rss,
      actor: actor,
      actor_type: actor_type,
      timestamp_ms: ts,
      availability: "measured"
    }
  end

  defp profile(cpu_mean, cpu_max, rss_max, count) do
    %{
      "cpu_percent" => %{count: count, mean: cpu_mean, max: cpu_max, min: 0.0, median: cpu_mean, p95: cpu_max},
      "rss_bytes" => %{count: count, mean: rss_max, max: rss_max, min: 0.0, median: rss_max, p95: rss_max}
    }
  end

  # Two agents active across the run plus an always-on daemon baseline; one ticket merges.
  defp dataset do
    times = for i <- 0..10, do: @t0 + i * 60_000

    %{
      actors: %{
        "_daemon" => %{
          samples: Enum.map(times, &sample("_daemon", "daemon", &1, 30.0, 100_000_000)),
          profile: profile(30.0, 40.0, 100_000_000, 11)
        },
        "ticket:5" => %{
          samples: Enum.map(times, &sample("ticket:5", "agent", &1, 50.0, 200_000_000)),
          profile: profile(50.0, 120.0, 220_000_000, 11)
        },
        "ticket:6" => %{
          samples: Enum.map(times, &sample("ticket:6", "agent", &1, 20.0, 150_000_000)),
          profile: profile(20.0, 60.0, 160_000_000, 11)
        }
      },
      tickets: %{
        "5" => %{
          complexity: 3,
          events: [%{event: "dispatch", timestamp_ms: @t0}],
          intervals: [
            %{phase: "dispatch", status: "point", start_ms: @t0, end_ms: nil},
            %{phase: "implement", status: "measured", start_ms: @t0 + 60_000, end_ms: @t0 + 360_000},
            %{phase: "pr_merged", status: "point", start_ms: @t0 + 480_000, end_ms: nil}
          ]
        },
        "6" => %{
          complexity: 1,
          events: [%{event: "dispatch", timestamp_ms: @t0 + 30_000}],
          intervals: [
            %{phase: "dispatch", status: "point", start_ms: @t0 + 30_000, end_ms: nil},
            %{phase: "implement", status: "measured", start_ms: @t0 + 90_000, end_ms: @t0 + 540_000},
            %{phase: "rework_start", status: "point", start_ms: @t0 + 570_000, end_ms: nil}
          ]
        }
      },
      provenance: %{time_range: %{start: iso(@t0 - 600_000), end: iso(@t0 + 1_800_000)}}
    }
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp model(opts \\ []) do
    Presenter.model(dataset(), Keyword.merge([cap: 4, cores: 4, host_mem_bytes: 1_000_000_000, buckets: 10], opts))
  end

  test "builds an available model with the requested bucket count" do
    m = model()
    assert m.available? == true
    assert length(m.series) == 10
    assert m.cpu_ceiling == 400
  end

  test "stacks only agent units and folds the daemon into the baseline" do
    m = model()
    assert Enum.map(m.actors, & &1.key) |> Enum.sort() == ["ticket:5", "ticket:6"]
    refute Enum.any?(m.actors, &(&1.kind == :daemon))
    # Daemon CPU lands in the baseline, never in a unit series.
    assert Enum.any?(m.series, &(&1.exec_cpu > 0))
    assert Enum.all?(m.series, &(not Map.has_key?(&1.per, "_daemon")))
    assert Enum.all?(m.series, &(map_size(&1.per) == 2))
  end

  test "humanizes agent labels and ranks units by CPU-seconds" do
    m = model()
    top = List.first(m.actors)
    assert top.key == "ticket:5"
    assert top.label == "#5"
    assert top.peak_cpu == 120.0
  end

  test "peak concurrency counts simultaneously active agents against the cap" do
    m = model()
    assert m.kpis.peak_conc == 2
    assert m.kpis.cap == 4
  end

  test "buckets exact fleet pressure independently of process availability" do
    daemon = %{
      samples: [
        pressure_sample(@t0 + 10_000, "unavailable", "current", "measured", 3, 4, 2, 1, 7, 12),
        pressure_sample(@t0 + 20_000, "measured", "current", "measured", 5, 6, 4, 2, 9, 18),
        pressure_sample(@t0 + 300_000, "measured", "stale", "degraded", 99, 99, 99, 99, 99, 99)
      ],
      profile: profile(0, 0, 0, 0)
    }

    pressure_dataset = put_in(dataset(), [:actors, "_daemon"], daemon)
    model = Presenter.model(pressure_dataset, cap: 10, cores: 4, buckets: 10)
    measured = Enum.find(model.series, &(Map.get(&1, :fleet_agents_occupied) == 5))

    assert measured.fleet_agents_effective == 4
    assert measured.build_gate_capacity == 2
    assert measured.build_gate_active == 2
    assert measured.build_gate_queued == 9
    assert measured.build_queue_oldest_wait_seconds == 18
    assert measured.pressure_state == :measured
    assert measured.fleet_capacity_observed_at_ms == @t0 + 19_998
    assert measured.build_gate_observed_at_ms == @t0 + 19_999
    assert Enum.any?(model.series, &(&1.pressure_state == :stale_fleet))
    assert model.pressure.peak_occupied == 5
    assert model.pressure.latest_effective_capacity == 4
    assert model.pressure.latest_build_capacity == 2
    assert model.pressure.latest_fleet_observed_at_ms == @t0 + 19_998
    assert model.pressure.latest_build_observed_at_ms == @t0 + 19_999
    assert model.pressure.longest_wait_seconds == 18
  end

  test "keeps missing source observation times unavailable in a later bucket" do
    daemon = %{
      samples: [
        pressure_sample(@t0 + 10_000, "measured", "current", "measured", 3, 4, 2, 1, 7, 12),
        pressure_sample(@t0 + 20_000, "measured", "current", "partial", 5, 6, 4, 2, 9, 18)
        |> Map.put(:fleet_capacity_observed_at_ms, nil)
        |> Map.put(:build_gate_observed_at_ms, nil)
        |> Map.put("build_gate_capacity", nil)
      ],
      profile: profile(0, 0, 0, 0)
    }

    model = Presenter.model(put_in(dataset(), [:actors, "_daemon"], daemon), cap: 10, cores: 4, buckets: 10)
    measured = Enum.find(model.series, &(Map.get(&1, :fleet_agents_occupied) == 5))

    assert measured.fleet_capacity_observed_at_ms == nil
    assert measured.build_gate_observed_at_ms == nil
    assert model.pressure.latest_fleet_observed_at_ms == nil
    assert model.pressure.latest_build_observed_at_ms == nil
    assert model.pressure.latest_build_capacity == nil
  end

  test "counts merged tickets and derives lifecycle status from real phases" do
    m = model()
    assert m.kpis.total == 2
    assert m.kpis.merged == 1

    by_id = Map.new(m.tickets, &{&1.id, &1})
    assert by_id["5"].status == :merged
    assert by_id["5"].merged_at == @t0 + 480_000
    assert by_id["6"].status == :rework
  end

  defp pressure_sample(ts, availability, fleet_status, build_status, occupied, max_agents, effective, active, queued, wait) do
    sample("_daemon", "daemon", ts, 0.0, 0)
    |> Map.merge(%{
      :availability => availability,
      :fleet_capacity_status => fleet_status,
      "fleet_agents_occupied" => occupied,
      "fleet_agents_configured" => max_agents,
      "fleet_agents_max" => max_agents,
      "fleet_agents_effective" => effective,
      :fleet_capacity_observed_at_ms => ts - 2,
      :build_gate_status => build_status,
      "build_gate_capacity" => 2,
      "build_gate_active" => active,
      "build_gate_queued" => queued,
      "build_queue_oldest_wait_seconds" => wait,
      :build_gate_observed_at_ms => ts - 1
    })
  end

  test "groups dispatch-time complexity with average wall-clock and emdash-ready empty tiers" do
    breakdown = model().complexity_breakdown

    assert Enum.find(breakdown, &(&1.tier == 1)) == %{tier: 1, count: 1, average_wall_clock_ms: 540_000}
    assert Enum.find(breakdown, &(&1.tier == 3)) == %{tier: 3, count: 1, average_wall_clock_ms: 480_000}
    assert Enum.find(breakdown, &(&1.tier == 2)) == %{tier: 2, count: 0, average_wall_clock_ms: nil}
  end

  test "wasted capacity accumulates idle slot-hours under the cap" do
    m = model()
    assert m.kpis.wasted_slot_hours > 0
    assert is_number(m.kpis.mean_util_pct)
    assert m.kpis.mem_headroom_pct >= 0 and m.kpis.mem_headroom_pct <= 100
  end

  test "full range widens the window beyond the active run" do
    run = model()
    full = model(range: :full)
    assert full.window.start_ms <= run.window.start_ms
    assert full.window.end_ms >= run.window.end_ms
  end

  test "an hours range narrows to the recent tail of the run" do
    run = model()
    tail = model(range: 0.05)
    assert tail.available? == true
    assert tail.window.end_ms - tail.window.start_ms <= run.window.end_ms - run.window.start_ms
  end

  test "falls back to the agent sample window when no ticket intervals exist" do
    dataset = %{
      actors: %{
        "ticket:9" => %{
          samples: [sample("ticket:9", "agent", @t0 + 60_000, 40.0, 1_000_000), sample("ticket:9", "agent", @t0 + 120_000, 40.0, 1_000_000)],
          profile: profile(40.0, 50.0, 1_000_000, 2)
        }
      },
      tickets: %{},
      provenance: %{time_range: %{start: iso(@t0 - 600_000), end: iso(@t0 + 1_800_000)}}
    }

    m = Presenter.model(dataset, cap: 2, cores: 2, host_mem_bytes: 1_000_000_000, buckets: 10)
    assert m.available? == true
    assert m.window.start_ms <= @t0 + 60_000
    assert m.kpis.total == 0
  end

  test "folds an operator baseline, marks paused tickets, and survives a missing provenance window" do
    dataset = %{
      actors: %{
        "_operator" => %{samples: [sample("_operator", "operator", @t0 + 60_000, 15.0, 500_000)], profile: profile(15.0, 20.0, 500_000, 1)},
        "ticket:7" => %{
          samples: [sample("ticket:7", "agent", @t0 + 60_000, 40.0, 1_000_000), sample("ticket:7", "agent", @t0 + 120_000, 45.0, 1_100_000)],
          profile: profile(42.0, 60.0, 1_100_000, 2)
        }
      },
      tickets: %{
        "7" => %{
          intervals: [
            %{phase: "dispatch", status: "point", start_ms: @t0, end_ms: nil},
            %{phase: "implement", status: "measured", start_ms: @t0 + 60_000, end_ms: @t0 + 120_000},
            %{phase: "agent_pause", status: "point", start_ms: @t0 + 130_000, end_ms: nil}
          ]
        }
      },
      provenance: %{}
    }

    m = Presenter.model(dataset, cap: 3, cores: 3, host_mem_bytes: 1_000_000_000, buckets: 8)
    assert m.available? == true
    assert Map.new(m.tickets, &{&1.id, &1})["7"].status == :paused
    assert Enum.any?(m.series, &(&1.exec_cpu > 0))
  end

  describe "build-order scope: many sessions on a compressed timeline" do
    @minute 60_000
    @day 86_400_000

    # Two half-hour sessions three days apart. Ticket 5 runs in both and merges
    # in the second; ticket 6 runs only in the first; ticket 8 belongs to another
    # build entirely.
    defp session_stamps(base), do: for(i <- 0..30, do: base + i * @minute)

    defp multi_session_dataset do
      first = session_stamps(@t0)
      second = session_stamps(@t0 + 3 * @day)

      %{
        records:
          Enum.map(first, &%{boot_id: "boot-a", timestamp_ms: &1, kind: "resource"}) ++
            Enum.map(second, &%{boot_id: "boot-b", timestamp_ms: &1, kind: "resource"}),
        actors: %{
          "_daemon" => %{
            samples: Enum.map(first ++ second, &sample("_daemon", "daemon", &1, 20.0, 100_000_000)),
            profile: profile(20.0, 30.0, 100_000_000, 62)
          },
          "ticket:5" => %{
            samples: Enum.map(first ++ second, &sample("ticket:5", "agent", &1, 50.0, 200_000_000)),
            profile: profile(50.0, 120.0, 220_000_000, 62)
          },
          "ticket:6" => %{
            samples: Enum.map(first, &sample("ticket:6", "agent", &1, 20.0, 150_000_000)),
            profile: profile(20.0, 60.0, 160_000_000, 31)
          }
        },
        tickets: %{
          "5" => %{
            intervals: [
              %{phase: "dispatch", status: "point", start_ms: @t0, end_ms: nil},
              %{phase: "implement", status: "measured", start_ms: @t0 + @minute, end_ms: @t0 + 20 * @minute},
              %{phase: "pr_merged", status: "point", start_ms: @t0 + 3 * @day + 10 * @minute, end_ms: nil}
            ]
          },
          "6" => %{
            intervals: [
              %{phase: "dispatch", status: "point", start_ms: @t0, end_ms: nil},
              %{phase: "implement", status: "measured", start_ms: @t0 + @minute, end_ms: @t0 + 25 * @minute}
            ]
          }
        },
        provenance: %{time_range: %{start: iso(@t0 - @minute), end: iso(@t0 + 3 * @day + 31 * @minute)}}
      }
    end

    defp long_run_model(opts) do
      Presenter.model(
        multi_session_dataset(),
        Keyword.merge([cap: 4, cores: 4, host_mem_bytes: 1_000_000_000, buckets: 12], opts)
      )
    end

    test "an active timeline measures the hour the build ran, not the three days it spanned" do
      absolute = long_run_model(timeline: :absolute)
      compressed = long_run_model(timeline: :active)

      absolute_span = absolute.window.end_ms - absolute.window.start_ms
      compressed_span = compressed.window.end_ms - compressed.window.start_ms

      assert absolute_span > 2 * @day
      assert_in_delta compressed_span, 60 * @minute, @minute
    end

    test "idle capacity is bounded by active hours, not calendar hours" do
      absolute = long_run_model(timeline: :absolute)
      compressed = long_run_model(timeline: :active)

      # This is the failure the compressed axis exists to prevent: over a
      # three-day span the naive number counts two idle nights as wasted agent
      # slots and reports hundreds of hours of "wasted capacity".
      assert absolute.kpis.wasted_slot_hours > 100
      assert compressed.kpis.wasted_slot_hours <= 4 * 1.0 + 0.1
    end

    test "a merge recorded in the second session lands inside the second session on the axis" do
      compressed = long_run_model(timeline: :active)
      row = Map.new(compressed.tickets, &{&1.id, &1})["5"]

      # 30 minutes of session one, then 10 minutes into session two.
      assert_in_delta row.merged_at, 40 * @minute, @minute
      assert row.status == :merged
    end

    test "ticket lifecycle rows stay ordered and inside the compressed window" do
      compressed = long_run_model(timeline: :active)

      assert Enum.all?(compressed.tickets, fn row ->
               row.start_ms >= compressed.window.start_ms and row.end_ms <= compressed.window.end_ms and
                 row.start_ms <= row.work_ms and row.work_ms <= row.end_ms
             end)
    end

    test "the session count reports the daemon boots the build touched" do
      assert long_run_model(timeline: :active).kpis.sessions == 2
    end

    test "cumulative CPU is reported in hours across every session" do
      kpis = long_run_model(timeline: :active).kpis

      assert kpis.cpu_hours > 0
      assert kpis.active_ms > 0
    end

    test "the burn-up denominator is the Build Order's membership, not the tickets that happened to run" do
      # Two members ran; the build has five. Without an explicit total this
      # reports 50% complete for a build that is 20% complete.
      inferred = long_run_model(timeline: :active)
      scoped = long_run_model(timeline: :active, scope_total: 5)

      assert inferred.kpis.total == 2
      assert scoped.kpis.total == 5
      assert scoped.kpis.merged == 1
      assert scoped.kpis.done_pct == 20
    end

    test "an absolute timeline leaves the live-session model on wall-clock timestamps" do
      absolute = long_run_model(timeline: :absolute)

      assert absolute.window.start_ms > @t0 - @day
      assert Map.new(absolute.tickets, &{&1.id, &1})["5"].merged_at == @t0 + 3 * @day + 10 * @minute
    end
  end
end
