defmodule Aiur.Experiments.TelemetryReaderTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.TelemetryReader
  @window %{start: ~U[2026-10-09 10:00:00Z], end: ~U[2026-10-09 12:00:00Z]}

  setup do
    path = Path.join(System.tmp_dir!(), "telemetry-reader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    %{path: path}
  end

  test "streams both formats and never opens known outside sources", %{path: path} do
    live = Path.join(path, "live.ndjson")
    summary = Path.join(path, "summary.json")
    File.write!(live, Jason.encode!(record("live")) <> "\n")
    File.write!(summary, Jason.encode!(%{records: [record("retained")]}))

    sources = [
      %{path: live, format: :ndjson},
      %{path: summary, format: :summary},
      %{path: "must-not-open", format: :summary, start: ~U[2026-10-09 12:00:00Z]},
      %{path: "past-must-not-open", format: :summary, end: ~U[2026-10-09 09:00:00Z]}
    ]

    owner = self()
    assert {:ok, result} = TelemetryReader.read(@window, sources, on_open: &send(owner, {:opened, &1}))
    assert result.state == :complete
    assert Enum.map(result.records, & &1.record_id) == ["live", "retained"]
    assert_receive {:opened, ^live}, 1_000
    assert_receive {:opened, ^summary}, 1_000
    refute_received {:opened, _}
  end

  test "record and byte limits bound retained and scanned data across files", %{path: path} do
    summary = Path.join(path, "large.json")
    live = Path.join(path, "large.ndjson")
    records = Enum.map(1..1000, &record(Integer.to_string(&1)))
    File.write!(summary, Jason.encode!(%{records: records}))
    File.write!(live, Enum.map_join(records, "\n", &Jason.encode!/1))

    for format <- [:summary, :ndjson] do
      source = %{path: if(format == :summary, do: summary, else: live), format: format}
      assert {:ok, bounded} = TelemetryReader.read(@window, [source], max_records: 3)
      assert bounded.state == :truncated
      assert bounded.stats.records_seen == 3
      assert Enum.map(bounded.records, & &1.record_id) == ["1", "2", "3"]
      assert {:ok, bytes} = TelemetryReader.read(@window, [source], max_bytes: 100)
      assert bytes.state == :truncated
      assert bytes.stats.bytes_read == 100
      assert {:ok, retained} = TelemetryReader.read(@window, [source], max_retained_bytes: 1)
      assert retained.state == :truncated
      assert retained.records == []
      assert retained.stats.retained_bytes == 0
    end
  end

  test "oversized JSON tokens stop incrementally and history preserves first dispatch", %{path: path} do
    summary = Path.join(path, "token.json")
    File.write!(summary, "{\"ignored\":\"" <> String.duplicate("x", 2_000_000) <> "\"}")
    assert {:ok, result} = TelemetryReader.read(@window, [%{path: summary, format: :summary}])
    assert result.state == :truncated
    assert result.stats.bytes_read < 1_100_000
    assert result.records == []
    live = Path.join(path, "old.ndjson")
    File.write!(live, Jason.encode!(Map.put(record("first"), :timestamp, "2026-10-09T09:00:00Z")))
    assert {:ok, old} = TelemetryReader.read(@window, [%{path: live, format: :ndjson}], history: true)
    assert Enum.map(old.records, & &1.record_id) == ["first"]
  end

  test "large derived actor maps are discarded without losing lifecycle evidence", %{path: path} do
    summary = Path.join(path, "projected.json")
    actors = Map.new(1..600, &{Integer.to_string(&1), %{profile: %{note: String.duplicate("x", 3_000)}, samples: []}})
    File.write!(summary, Jason.encode!(%{actors: actors, records: [record("survives")]}))
    assert File.stat!(summary).size > 1_048_576
    assert {:ok, %{state: :complete, records: [retained]}} = TelemetryReader.read(@window, [%{path: summary, format: :summary}])
    assert retained.record_id == "survives"
  end

  test "a nested kind tag is metadata rather than a second telemetry record", %{path: path} do
    summary = Path.join(path, "tagged.json")
    tagged = %{record("tagged") | kind: "run_context", attributes: %{"capture_tags" => %{"kind" => "baseline"}}}
    File.write!(summary, Jason.encode!(%{records: [tagged]}))
    assert {:ok, %{state: :complete, records: [row]}} = TelemetryReader.read(@window, [%{path: summary, format: :summary}])
    assert row.attributes["capture_tags"] == %{"kind" => "baseline"}
  end

  defp record(id) do
    %{schema_version: 3, kind: "lifecycle", timestamp: "2026-10-09T11:00:00Z", boot_id: "boot", sequence: 1, record_id: id, attributes: %{ticket: "101", event: "dispatch"}}
  end
end
