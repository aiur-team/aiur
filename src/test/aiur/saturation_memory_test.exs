defmodule Aiur.SaturationMemoryTest do
  use ExUnit.Case, async: true
  alias Aiur.SaturationSentinel

  test "a real VM sample persists numeric memory diagnostics as JSON" do
    path = Path.join(Aiur.TestSupport.tmp_root!("saturation-memory"), "sample.ndjson")
    snapshot = SaturationSentinel.snapshot(load_fun: fn -> 27.5 end)
    assert :ok = SaturationSentinel.record(path, snapshot)
    recorded = path |> File.read!() |> Jason.decode!()
    assert recorded["memory"]["total"] == snapshot.memory.total
    assert recorded["memory"]["processes"] == snapshot.memory.processes
  end
end
