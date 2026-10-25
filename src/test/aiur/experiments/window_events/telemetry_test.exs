defmodule Aiur.Experiments.WindowEvents.TelemetryTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.WindowEvents.Local

  setup do
    root = Path.join(System.tmp_dir!(), "event-telemetry-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  test "collection streams live and summary boot heads, excludes outside sources and preserves partial coverage", %{root: root} do
    raw = Path.join(root, "telemetry.ndjson")
    summary = Path.join(root, "run-summary.json")
    File.write!(raw, Jason.encode!(boot("new", "2026-10-09T04:00:00Z")) <> "\n{bad\n")
    File.write!(summary, Jason.encode!(%{records: [boot("old", "2026-10-09T01:00:00Z")]}))
    owner = self()
    sources = [%{path: raw, format: :ndjson}, %{path: summary, format: :summary}, %{path: "must-not-open", format: :summary, end: ~U[2026-10-08 00:00:00Z]}]

    {events, missing} = Local.collect(options(sources, on_open: &send(owner, {:opened, &1})))
    assert [%{"kind" => "outage", "from" => "2026-10-09T01:00:00Z", "to" => "2026-10-09T04:00:00Z"}] = events
    assert "telemetry" in missing
    assert_receive {:opened, ^raw}, 1_000
    assert_receive {:opened, ^summary}, 1_000
    refute_received {:opened, _}
  end

  test "collection passes its byte budget to the shared reader and exposes truncation", %{root: root} do
    raw = Path.join(root, "large.ndjson")
    File.write!(raw, Jason.encode!(boot("one", "2026-10-09T01:00:00Z")) <> "\n" <> Jason.encode!(boot("two", "2026-10-09T04:00:00Z")))
    source = [%{path: raw, format: :ndjson}]
    {complete, missing} = Local.collect(options(source))
    assert [%{"kind" => "outage"}] = complete
    refute "telemetry" in missing
    {[], truncated} = Local.collect(options(source, max_bytes: 32))
    assert "telemetry" in truncated
  end

  test "the shared projection retains fleet caps and context transitions", %{root: root} do
    raw = Path.join(root, "fleet.ndjson")

    rows = [
      row("run_context", "1", "2026-10-09T01:00:00Z", %{aiur_vsn: "1", config_hash: "a", config_section_hashes: %{agent: "a"}}),
      row("run_context", "2", "2026-10-09T02:00:00Z", %{aiur_vsn: "2", config_hash: "b", config_section_hashes: %{agent: "b"}}),
      row("resource", "3", "2026-10-09T01:00:00Z", %{actor: "_daemon", fleet_agents_max: 8, fleet_agents_effective: 8}),
      row("resource", "4", "2026-10-09T02:00:00Z", %{actor: "_daemon", fleet_agents_max: 4, fleet_agents_effective: 4}),
      row("resource", "5", "2026-10-09T04:00:00Z", %{actor: "_daemon", fleet_agents_max: 4, fleet_agents_effective: 4})
    ]

    File.write!(raw, Enum.map_join(rows, "\n", &Jason.encode!/1))
    {events, missing} = Local.collect(options([%{path: raw, format: :ndjson}]))
    assert Enum.sort(Enum.map(events, & &1["kind"])) == ~w(capacity_change config_change version_change)
    assert Enum.find(events, &(&1["kind"] == "capacity_change"))["attrs"] == %{"max" => 4, "effective" => 4}
    assert Enum.find(events, &(&1["kind"] == "config_change"))["attrs"]["changed_keys"] == ["agent"]
    refute "telemetry" in missing
  end

  defp options(sources, reader_options \\ []) do
    [range_start: "2026-10-09T01:00:00Z", range_end: "2026-10-10T00:00:00Z", telemetry_sources: sources, telemetry_reader_options: reader_options, alert_files: []]
  end

  defp boot(id, at), do: %{schema_version: 3, kind: "restart", boot_id: id, record_id: id, sequence: 1, timestamp: at, attributes: %{event: "daemon_restart"}}
  defp row(kind, id, at, attrs), do: %{schema_version: 3, kind: kind, boot_id: "boot", record_id: id, sequence: 1, timestamp: at, attributes: attrs}
end
