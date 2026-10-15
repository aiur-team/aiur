defmodule Aiur.Experiments.WindowEvents.LocalTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.WindowEvents.Local

  defp record(kind, at, attrs, boot \\ "boot-a"), do: %{"kind" => kind, "timestamp" => at, "boot_id" => boot, "attributes" => attrs}
  defp sample(at, cap, effective \\ nil), do: record("resource", at, %{"fleet_agents_max" => cap, "fleet_agents_effective" => effective || cap})

  test "two boot records three hours apart yield one outage with exact endpoints" do
    rows = [record("restart", "2026-10-09T01:00:00Z", %{"event" => "daemon_restart"}), record("restart", "2026-10-09T04:00:00Z", %{"event" => "daemon_restart"}, "boot-b")]
    assert [%{"kind" => "outage", "from" => "2026-10-09T01:00:00Z", "to" => "2026-10-09T04:00:00Z"}] = Local.outages(rows ++ [hd(rows)])
  end

  test "capacity decrease held two hours yields one change and a five minute blip yields none" do
    baseline = sample("2026-10-09T01:00:00Z", 8)
    drop = sample("2026-10-09T02:00:00Z", 4)
    assert [%{"kind" => "capacity_change", "from" => "2026-10-09T02:00:00Z", "attrs" => %{"max" => 4, "effective" => 4}}] = Local.capacity([baseline, drop, sample("2026-10-09T04:00:00Z", 4)])
    assert Local.capacity([baseline, drop, sample("2026-10-09T02:05:00Z", 8), sample("2026-10-09T04:00:00Z", 8)]) == []
  end

  test "effective cap zero gives a pause with its resume endpoint" do
    assert [%{"kind" => "global_pause", "from" => "2026-10-09T02:00:00Z", "to" => "2026-10-09T02:05:00Z"}] =
             Local.capacity([sample("2026-10-09T01:00:00Z", 8), sample("2026-10-09T02:00:00Z", 8, 0), sample("2026-10-09T02:05:00Z", 8), sample("2026-10-09T04:00:00Z", 8)])
  end

  test "run context transitions preserve version and changed config sections" do
    rows = [
      record("run_context", "2026-10-09T01:00:00Z", %{"aiur_vsn" => "1", "config_hash" => "a", "config_section_hashes" => %{"agent" => "1"}}),
      record("run_context", "2026-10-09T02:00:00Z", %{"aiur_vsn" => "2", "config_hash" => "b", "config_section_hashes" => %{"agent" => "2"}})
    ]

    {events, missing} = Local.collect(records_fun: fn _ -> {rows, []} end, alert_files: [])
    assert Enum.find(events, &(&1["kind"] == "version_change"))["attrs"] == %{"before" => "1", "after" => "2"}
    assert Enum.find(events, &(&1["kind"] == "config_change"))["attrs"] == %{"before" => "a", "after" => "b", "changed_keys" => ["agent"]}
    refute "version_change" in missing
    refute "config_change" in missing
  end

  test "missing telemetry stays explicit instead of producing an apparently complete empty ledger" do
    {[], missing} = Local.collect(records_fun: fn _ -> {[], ["telemetry"]} end, alert_files: [])
    assert Enum.sort(missing) == ~w(capacity_change config_change global_pause telemetry version_change)
  end
end
