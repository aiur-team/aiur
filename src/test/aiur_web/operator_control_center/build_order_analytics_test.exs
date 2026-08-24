defmodule AiurWeb.OperatorControlCenter.BuildOrderAnalyticsTest do
  @moduledoc """
  The Build Order analytics pane renders its own KPI strip, so it can regress
  independently of the run strip on `/analytics`. Before #2241 both read
  `k.cap` — the configured value — and reverting either one alone left every
  test green.
  """

  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.Analytics.Presenter
  alias AiurWeb.OperatorControlCenter.BuildOrderAnalytics

  @t0 1_000_000
  @scope %{total: 2, state: :ok}

  test "renders the effective cap, its binding constraint, and the ceilings above it" do
    html = render_pane(cap: 3, session_cap: 8, configured_cap: 16, cap_binding: "AIMD envelope")

    assert html =~ "of 3 cap (binding: AIMD envelope, session 8, configured 16)"
    refute html =~ "of 16 cap"
    refute html =~ "of 8 cap"
  end

  test "reports no capacity-elsewhere figure when no effective cap is known" do
    html = render_pane(cap_available?: false, configured_cap: nil, session_cap: nil)

    assert html =~ "of unknown cap"
    # Idle slot-hours are a subtraction from the cap, so an unknown cap has no
    # figure. A precise hour count here would be derived from a ceiling the
    # pane just said it does not have.
    assert html =~ ~r/Capacity elsewhere<\/span>\s*<span class="an-kpi-val">—</
  end

  defp render_pane(cap_opts) do
    model = Presenter.model(dataset(), Keyword.merge([cap: 4, buckets: 4, cores: 8], cap_opts))

    render_component(&BuildOrderAnalytics.build_order_analytics/1, scope: @scope, model: model)
  end

  # A minimal two-agent dataset in the real reduced-telemetry shape: enough for
  # the KPI strip to compute a genuine peak concurrency and idle-slot integral.
  defp dataset do
    times = for i <- 0..4, do: @t0 + i * 60_000

    %{
      actors: %{
        "ticket:5" => %{
          samples: Enum.map(times, &sample("ticket:5", "agent", &1, 50.0, 200_000_000)),
          profile: profile(50.0, 120.0, 220_000_000, 5)
        },
        "ticket:6" => %{
          samples: Enum.map(times, &sample("ticket:6", "agent", &1, 20.0, 150_000_000)),
          profile: profile(20.0, 60.0, 160_000_000, 5)
        }
      },
      tickets: %{
        "5" => %{
          complexity: 3,
          events: [%{event: "dispatch", timestamp_ms: @t0}],
          intervals: [%{phase: "pr_merged", status: "point", start_ms: @t0 + 240_000, end_ms: nil}]
        },
        "6" => %{
          complexity: 1,
          events: [%{event: "dispatch", timestamp_ms: @t0}],
          intervals: [%{phase: "implement", status: "measured", start_ms: @t0, end_ms: @t0 + 240_000}]
        }
      },
      provenance: %{time_range: %{start: @t0, end: @t0 + 240_000}}
    }
  end

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
end
