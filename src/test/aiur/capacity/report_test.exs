defmodule Aiur.Capacity.ReportTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.Capacity.{Report, ReportCLI}

  @since ~U[2026-11-01 00:00:00Z]

  defp sample(at, accounts, sources \\ []), do: %{"schema" => 1, "at" => at, "accounts" => accounts, "sources" => sources}

  defp row(backend, account, fields), do: Map.merge(%{"backend" => backend, "account" => account, "freshness" => "fresh", "running" => 0}, fields)

  defp dispatch(at, ticket, backend, fields \\ %{}) do
    %{"timestamp" => at, "attributes" => Map.merge(%{"event" => "dispatch", "boundary" => "point", "ticket" => ticket, "backend" => backend, "priority" => "codex,claude,openrouter"}, fields)}
  end

  defp samples do
    [
      # Before `since`: ignored.
      sample("2026-10-31T23:00:00Z", [row("claude", "default", %{"reserve_percent" => 30, "projected_percent" => 1, "running" => 1})]),
      sample(
        "2026-11-02T10:00:00Z",
        [
          row("claude", "default", %{"reserve_percent" => 30, "remaining_percent" => 33, "projected_percent" => 27, "running" => 1}),
          row("claude", "spare", %{"reserve_percent" => 30, "remaining_percent" => 80}),
          row("openrouter", nil, %{"freshness" => "unknown", "remaining_percent" => 5})
        ],
        [
          %{"backend" => "openrouter", "period" => "daily", "period_start" => "2026-11-02", "spend_usd" => 4.0, "limit_usd" => 5},
          %{"backend" => "openrouter", "period" => "monthly", "period_start" => "2026-11-01", "spend_usd" => nil, "limit_usd" => 40}
        ]
      ),
      sample(
        "2026-11-02T10:05:00.123456Z",
        [
          row("claude", "default", %{"reserve_percent" => 30, "remaining_percent" => 25}),
          row("codex", nil, %{"freshness" => "unavailable", "remaining_percent" => nil})
        ],
        [%{"backend" => "openrouter", "period" => "daily", "period_start" => "2026-11-02", "spend_usd" => 5.5, "limit_usd" => 5}]
      )
    ]
  end

  defp dispatches do
    allow = %{"route" => "codex", "verdict" => "allow"}
    held = %{"route" => "claude", "verdict" => "hold"}

    [
      dispatch("2026-10-30T00:00:00Z", "1", "codex"),
      # Joined to the 10:00 sample: projected 27 <= reserve 30.
      dispatch("2026-11-02T10:01:00Z", "2", "claude", %{"account" => "default"}),
      # Joined to the 10:00 sample: spare has 80 > 30.
      dispatch("2026-11-02T10:02:00Z", "3", "claude", %{"account" => "spare"}),
      dispatch("2026-11-02T10:03:00Z", "4", "codex"),
      dispatch("2026-11-02T10:04:00Z", "5", "openrouter:kimi", %{"candidates" => [allow, %{"route" => "openrouter", "verdict" => "allow"}]}),
      dispatch("2026-11-02T10:06:00Z", "6", "openrouter:kimi", %{"candidates" => [held], "priority" => "claude,codex"}),
      # No verdicts recorded: unknown, and no sample for this account before it: reserve unknown.
      dispatch("2026-11-02T10:07:00Z", "7", "openrouter:kimi", %{"priority" => "claude,codex"}),
      %{"timestamp" => "2026-11-02T10:08:00Z", "attributes" => %{"event" => "dispatch", "boundary" => "start", "backend" => "codex"}}
    ]
  end

  defp metric(report, key), do: Enum.find(report.metrics, &(&1.key == key))

  test "each section 8 metric carries its count, population and unknowns" do
    report = Report.build(samples(), dispatches(), @since)

    assert report.dispatches == 6 and report.samples == 2

    assert %{count: 1, population: 2, items: [%{ticket: "2", figure: 27, reserve: 30}]} = metric(report, "reserve_broken")
    # Dispatches 4-7 have no reserved row before them (codex/openrouter rows carry no reserve).
    assert metric(report, "reserve_broken").unknown == 4

    # Two samples at or below reserve (27 and 25); only the first had a worker running.
    assert %{count: 1, population: 2, items: [%{running: 1, figure: 27}]} = metric(report, "reserve_low_with_worker")
    assert %{count: 1, population: 6, unknown: 0} = metric(report, "codex_share")
    assert %{count: 1, population: 3, unknown: 1, items: [%{ticket: "5"}]} = metric(report, "openrouter_other_allowed")
    assert %{count: 1, population: 2, unknown: 1, items: [%{period: "daily", spend_usd: 5.5, limit_usd: 5}]} = metric(report, "limit_exceeded")
    assert %{count: 1, population: 2, items: [%{backend: "openrouter"}]} = metric(report, "unknown_as_number")
  end

  test "windows split at each agent.priority change and count codex share inside each" do
    report = Report.build(samples(), dispatches(), @since)

    assert [
             %{priority: "codex,claude,openrouter", dispatches: 4, codex: 1, from: "2026-11-02T10:01:00Z", to: "2026-11-02T10:04:00Z"},
             %{priority: "claude,codex", dispatches: 2, codex: 0}
           ] = report.windows
  end

  test "the text report names every metric with its population and each priority window" do
    text = Report.render(Report.build(samples(), dispatches(), @since))

    assert text =~ "worker dispatches that broke a reserve: 1 of 2 (unknown 4)"
    assert text =~ "codex dispatches / all coding dispatches: 1 of 6 (unknown 0)"
    assert text =~ "openrouter dispatches while another source was allowed: 1 of 3 (unknown 1)"
    assert text =~ "source periods whose recorded spend passed its limit: 1 of 2 (unknown 1)"
    assert text =~ "unknown readings shown as a number: 1 of 2 (unknown 0)"
    assert text =~ "agent.priority=codex,claude,openrouter  codex 1/4 dispatches (25.0%)"
    assert text =~ "agent.priority=claude,codex  codex 0/2 dispatches (0.0%)"
  end

  test "no data reports zero populations rather than failing" do
    report = Report.build([], [], @since)
    assert Enum.all?(report.metrics, &(&1.population == 0 and &1.count == 0))
    assert report.windows == []
  end

  @tag :tmp_dir
  test "the CLI reads every retained run's logs and skips torn lines", %{tmp_dir: tmp_dir} do
    for {run, lines} <- [{"run-a", samples()}, {"run-b", []}] do
      dir = Path.join([tmp_dir, run, "log"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "capacity.ndjson"), Enum.map_join(lines, "", &(Jason.encode!(&1) <> "\n")) <> "{torn\n")
    end

    telemetry = Enum.map_join(dispatches(), "", &(Jason.encode!(&1) <> "\n"))
    File.write!(Path.join([tmp_dir, "run-a", "log", "telemetry.ndjson"]), telemetry)
    File.write!(Path.join([tmp_dir, "run-b", "log", "telemetry.ndjson.1"]), Jason.encode!(dispatch("2026-11-03T00:00:00Z", "8", "codex")) <> "\n")

    json = capture_io(fn -> assert ReportCLI.run("2026-11-01", true, logs_root: tmp_dir) == 0 end)
    report = Jason.decode!(json)

    assert report["dispatches"] == 7 and report["samples"] == 2
    assert Enum.find(report["metrics"], &(&1["key"] == "codex_share")) |> Map.take(["count", "population"]) == %{"count" => 2, "population" => 7}
  end

  test "the CLI refuses a since that is not a date or time" do
    assert capture_io(:stderr, fn -> assert ReportCLI.run("last week", false, logs_root: "unused") == 64 end) =~ "--since takes a date"
    assert {:ok, ~U[2026-11-01 06:00:00Z]} = ReportCLI.parse_since("2026-11-01T06:00:00Z")
  end
end
