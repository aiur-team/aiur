defmodule Aiur.RunTelemetry.SamplerBindingKindTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.Sampler

  @full_cap %{occupied: 4, configured: 4, max: 4, effective: 4, available: 0}

  test "a full cap gives config_cap and an admission hold gives admission" do
    assert daemon(fn -> {:current, %{capacity: @full_cap}, %{age_ms: 0}} end).fleet_binding_kind == "config_cap"

    held = Map.put(@full_cap, :capacity_hold, %{signal: :load, measured: 9, threshold: 4})
    assert daemon(fn -> {:current, %{capacity: held}, %{age_ms: 0}} end).fleet_binding_kind == "admission"
  end

  test "an unpublished snapshot gives nil and names the field as partial" do
    daemon = daemon(fn -> :snapshot_unpublished end)

    assert daemon.fleet_binding_kind == nil
    assert :fleet_binding_kind in daemon.partial_fields
  end

  defp daemon(fleet_snapshot_fun) do
    result =
      Sampler.sample_once(%{},
        process_table_fun: fn -> {:error, :reader_failed} end,
        entries_fun: fn -> [] end,
        daemon_pid: nil,
        operator_pid: nil,
        fd_headroom_fun: fn -> :unavailable end,
        system_ms_fun: fn -> 42 end,
        fleet_snapshot_fun: fn -> Aiur.Orchestrator.TelemetryEvents.binding_snapshot(fleet_snapshot_fun.()) end,
        build_status_fun: fn -> %{enabled?: false} end
      )

    Enum.find(result.records, &(&1.actor == "_daemon"))
  end
end
