defmodule Aiur.RunTelemetry.DashboardTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.{Dashboard, Dataset}

  @fixtures Path.expand("../../fixtures/run_telemetry", __DIR__)

  test "writes a self-contained dashboard with ordered evidence sections" do
    output = temporary_output!()

    assert {:ok, result} =
             Dashboard.generate(@fixtures, output,
               now: ~U[2026-07-11 00:02:00Z],
               generated_at: ~U[2026-07-11 16:00:00Z]
             )

    assert result.output == output
    assert result.dataset.provenance.record_count > 0
    html = File.read!(output)

    assert {:ok, document} = Floki.parse_document(html)
    assert Floki.find(document, "script#aiur-data[type='application/json']") != []
    assert Floki.find(document, "style") |> length() == 1

    assert Floki.find(document, "main > section") |> Enum.map(&Floki.attribute(&1, "id")) == [
             ["run-evidence"],
             ["review-findings"],
             ["actor-timeline"],
             ["fleet-pressure"],
             ["ticket-lifecycle"],
             ["resource-profiles"],
             ["operational-notes"]
           ]

    assert Floki.find(document, "#resource-metric") != []
    assert Floki.find(document, "#actor-table-more[aria-controls='actor-table-body']") != []
    assert Floki.find(document, "#ticket-filter") != []
    assert Floki.find(document, "#reset-zoom") != []
    assert Floki.find(document, "#phase-legend") != []
    assert Floki.find(document, "#actor-table caption") != []
    assert Floki.find(document, "#pressure-chart") != []
    assert Floki.find(document, "#pressure-table caption") != []
    assert Floki.find(document, "#pressure-table-more[aria-controls='pressure-table-body']") != []
    assert Floki.find(document, "#lifecycle-table caption") != []
    assert html =~ "prefers-reduced-motion: reduce"
    assert html =~ "focus-visible"
    assert html =~ "Broken pause → resume"
    assert html =~ ~S(value === null || value === undefined || value === "")
    assert html =~ "decimateSamples"
    assert html =~ "appendPressureTablePage"
    assert html =~ "Fleet observed"
    assert html =~ "Build observed"
    assert html =~ "Build capacity"
    refute html =~ "Math.min(...samples"
    refute html =~ "Math.max(1,...samples"
    refute html =~ "samples.flatMap(s=>countKeys"
    assert html =~ ~s(sample.fleet_capacity_status === "current")
    assert html =~ ~S|["measured","disabled","partial"].includes(sample.build_gate_status)|

    json = Floki.find(document, "#aiur-data") |> Floki.text(js: true)
    payload = Jason.decode!(json)
    point = Enum.find(payload["tickets"]["930"]["intervals"], &(&1["status"] == "point"))
    assert point["end_at"] == nil
    assert is_boolean(hd(payload["restarts"])["existing_records"])
  end

  test "renders healthy pressure despite unavailable daemon procfs and gaps degraded values" do
    {:ok, dataset} = Dataset.build(@fixtures)
    daemon = dataset.actors["_daemon"]

    samples = [
      %{
        :actor => "_daemon",
        :actor_type => "daemon",
        :timestamp => "2026-07-11T00:00:01Z",
        :timestamp_ms => 1_783_728_001_000,
        :availability => "unavailable",
        :fleet_capacity_status => "current",
        "fleet_agents_occupied" => 13,
        "fleet_agents_configured" => 16,
        "fleet_agents_max" => 16,
        "fleet_agents_effective" => 12,
        :fleet_capacity_observed_at_ms => 1_783_727_980_000,
        :build_gate_status => "measured",
        "build_gate_capacity" => 3,
        "build_gate_active" => 2,
        "build_gate_queued" => 8,
        "build_queue_oldest_wait_seconds" => 189,
        :build_gate_observed_at_ms => 1_783_727_995_000
      },
      %{
        :actor => "_daemon",
        :actor_type => "daemon",
        :timestamp => "2026-07-11T00:00:02Z",
        :timestamp_ms => 1_783_728_002_000,
        :availability => "measured",
        :fleet_capacity_status => "stale",
        "fleet_agents_occupied" => 99,
        :build_gate_status => "degraded",
        "build_gate_active" => 99
      }
    ]

    html = Dashboard.render(put_in(dataset, [:actors, "_daemon"], %{daemon | samples: samples}))
    assert html =~ "Fleet-wide build pressure"
    assert html =~ "Missing or degraded observations remain gaps"
    assert html =~ "fleet_agents_occupied"
    assert html =~ "build_gate_capacity"
    assert html =~ "fleet_capacity_observed_at_ms"
    assert html =~ "build_gate_observed_at_ms"
    assert html =~ "degraded build"
  end

  test "renders telemetry inputs through the same reducer without writing an artifact" do
    assert {:ok, %{html: html, dataset: dataset}} =
             Dashboard.render_inputs(@fixtures,
               now: ~U[2026-07-11 00:02:00Z],
               generated_at: ~U[2026-07-11 16:00:00Z]
             )

    assert dataset.provenance.record_count > 0
    assert html =~ ~s(<script id="aiur-data" type="application/json">)
    assert {:ok, _document} = Floki.parse_document(html)
  end

  test "escapes script-closing input and never references external assets or fetch" do
    {:ok, dataset} = Dataset.build(@fixtures)

    dataset =
      put_in(
        dataset.provenance.inputs,
        ["</script><script src=https://attacker.invalid/payload.js>alert(1)</script>"]
      )

    html = Dashboard.render(dataset, generated_at: ~U[2026-07-11 16:00:00Z])

    refute html =~ "</script><script src=https://attacker.invalid"
    assert html =~ "\\u003C/script\\u003E"
    refute html =~ ~r/<(?:script|link|img)[^>]+(?:src|href)=["']https?:/i
    refute html =~ ~r/@import\s/i
    refute html =~ ~r/\bfetch\s*\(/
    assert {:ok, _document} = Floki.parse_document(html)
  end

  test "renders explicit empty and unavailable states" do
    {:ok, dataset} = Dataset.build(@fixtures)

    dataset = %{dataset | actors: %{}, tickets: %{}, findings: [], restarts: [], warnings: []}
    html = Dashboard.render(dataset)

    assert html =~ "No actor resource samples were recorded."
    assert html =~ "No ticket lifecycle events were recorded."
    assert html =~ "No review pause/resume findings."
    assert html =~ "Unavailable samples"
  end

  test "returns an explicit write error for an unusable output path" do
    output = temporary_output!()
    File.mkdir_p!(output)

    assert {:error, :eisdir} = Dashboard.generate(@fixtures, output)
  end

  test "keeps GitHub enrichment failures visible without blocking local output" do
    output = temporary_output!()

    enricher = fn _repo, _tickets, _opts ->
      %{events: [], warnings: [%{type: :github_enrichment_failed, endpoint: :pull_requests, reason: "timeout"}]}
    end

    assert {:ok, result} =
             Dashboard.generate(@fixtures, output,
               repo: "owner/repo",
               github_enricher: enricher
             )

    assert Enum.any?(result.dataset.warnings, &(&1.type == :github_enrichment_failed))
    assert File.read!(output) =~ "github_enrichment_failed"
  end

  defp temporary_output! do
    root = Aiur.TestSupport.tmp_root!("aiur-dashboard")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Path.join(root, "analytics.html")
  end
end
