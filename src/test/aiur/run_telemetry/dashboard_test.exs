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
             ["ticket-lifecycle"],
             ["resource-profiles"],
             ["operational-notes"]
           ]

    assert Floki.find(document, "#resource-metric") != []
    assert Floki.find(document, "#ticket-filter") != []
    assert Floki.find(document, "#reset-zoom") != []
    assert Floki.find(document, "#phase-legend") != []
    assert Floki.find(document, "#actor-table caption") != []
    assert Floki.find(document, "#lifecycle-table caption") != []
    assert html =~ "prefers-reduced-motion: reduce"
    assert html =~ "focus-visible"
    assert html =~ "Broken pause → resume"

    json = Floki.find(document, "#aiur-data") |> Floki.text(js: true)
    payload = Jason.decode!(json)
    point = Enum.find(payload["tickets"]["930"]["intervals"], &(&1["status"] == "point"))
    assert point["end_at"] == nil
    assert is_boolean(hd(payload["restarts"])["existing_records"])
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

  defp temporary_output! do
    root = Path.join(System.tmp_dir!(), "aiur-dashboard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Path.join(root, "analytics.html")
  end
end
