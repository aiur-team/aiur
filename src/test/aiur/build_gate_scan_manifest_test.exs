defmodule Aiur.BuildGateScanManifestTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildGate

  # #3991: a BEAM killed mid-scan leaves its manifest in the shared tmp dir, and
  # a per-VM counter name collides with it in every later VM.
  test "status is not degraded by scan manifests another VM left behind" do
    gate_dir = Aiur.TestSupport.tmp_root!("aiur-build-gate-scan-manifest")
    assert {:ok, _canonical} = BuildGate.prepare_writable_root(gate_dir: gate_dir, slots: 1)
    next = System.unique_integer([:positive, :monotonic])

    stale =
      for n <- next..(next + 200) do
        path = Path.join(System.tmp_dir!(), "aiur-build-gate-scan-#{n}.json")
        File.write!(path, "{}")
        path
      end

    on_exit(fn ->
      Enum.each(stale, &File.rm/1)
      File.rm_rf!(gate_dir)
      File.rm_rf!(BuildGate.lock_dir(gate_dir))
    end)

    status =
      BuildGate.status(gate_dir: gate_dir, capacity: 1, stagger_seconds: 0, min_free_memory_mb: nil, strategy: :linux_lock)

    refute Map.get(status, :degraded?, false), inspect(status)
    assert %{enabled?: true, active: 0, queued: 0} = status
  end
end
