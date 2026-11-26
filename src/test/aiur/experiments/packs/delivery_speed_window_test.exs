defmodule Aiur.Experiments.Packs.DeliverySpeedWindowTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Packs.DeliverySpeed.TelemetrySource

  test "production history reads unindexed boots but omits future facts and the current boot" do
    root = Path.join(System.tmp_dir!(), "delivery-window-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    times = %{"old" => "2026-10-08T10:00:00Z", "inside" => "2026-10-09T10:00:00Z", "future" => "2026-10-09T12:00:00Z"}

    for {boot, at} <- times do
      body = %{
        records: [
          %{
            kind: "restart",
            boot_id: boot,
            timestamp: at,
            timestamp_iso: at,
            timestamp_ms: DateTime.to_unix(DateTime.from_iso8601(at) |> elem(1), :millisecond),
            schema_version: 3,
            sequence: 1,
            record_id: boot <> ":1",
            attributes: %{event: "daemon_restart"}
          }
        ]
      }

      File.write!(Path.join(root, boot), Jason.encode!(body))
    end

    at = "2026-10-09T10:30:00Z"

    anchor = %{
      kind: "lifecycle",
      boot_id: "github",
      timestamp: at,
      timestamp_iso: at,
      timestamp_ms: DateTime.to_unix(DateTime.from_iso8601(at) |> elem(1), :millisecond),
      schema_version: 3,
      sequence: 1,
      record_id: "anchor:1",
      attributes: %{event: "pr_merged", ticket: "100", boundary: "point"}
    }

    future = Jason.decode!(File.read!(Path.join(root, "future")))["records"] |> Enum.map(&Map.merge(&1, %{"boot_id" => "anchored", "record_id" => "anchored:1"}))
    File.write!(Path.join(root, "anchored"), Jason.encode!(%{records: [anchor | future]}))
    path = &Path.join(root, &1)

    self_owner = self()

    ctx = %{
      telemetry_enabled: true,
      github_window: %{"runs" => [%{"id" => 101, "name" => "CI", "event" => "pull_request", "conclusion" => "failure"}], "required_workflows" => ["CI"], "pulls" => []},
      boot_id: "current",
      telemetry_path: Path.join(root, "missing"),
      summary_boot_ids: fn -> ["old", "inside", "future", "anchored", "current"] end,
      summary_path: path,
      telemetry_reader_options: [on_open: fn loaded -> send(self_owner, {:summary_loaded, Path.basename(loaded)}) end]
    }

    window = %{start: ~U[2026-10-09 09:00:00Z], end: ~U[2026-10-09 11:00:00Z]}
    assert {:ok, data} = TelemetrySource.load(window, ctx)
    assert data.earliest_at == ~U[2026-10-08 10:00:00Z]
    assert data.ci_runs == [%{"id" => 101, "name" => "CI", "event" => "pull_request", "conclusion" => "failure"}]
    assert "ci_runs" in data.facts
    assert_received {:summary_loaded, "old"}
    assert_received {:summary_loaded, "inside"}
    assert_received {:summary_loaded, "anchored"}
    assert_received {:summary_loaded, "future"}
    refute_received {:summary_loaded, _boot}
  end

  test "unindexed corrupt history is partial rather than skipped" do
    path = Path.join(System.tmp_dir!(), "delivery-bound-#{System.unique_integer([:positive])}")
    File.write!(path, "{")
    on_exit(fn -> File.rm!(path) end)
    live = Path.expand("../../../fixtures/experiments/telemetry/boot-b.ndjson", __DIR__)
    ctx = %{telemetry_enabled: true, boot_id: "current", telemetry_path: live, summary_boot_ids: fn -> ["legacy"] end, summary_path: fn _ -> path end}
    assert {:ok, %{partial?: true}} = TelemetrySource.load(%{start: ~U[2026-10-09 09:00:00Z], end: ~U[2026-10-09 14:00:00Z]}, ctx)
  end
end
