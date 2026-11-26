defmodule Aiur.Experiments.AutoTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Aiur.Experiments.Auto
  alias Aiur.Experiments.Auto.Line

  test "non-recording and disabled configuration return no automatic children" do
    config = %Aiur.Config.Schema.Experiments.Auto{}
    assert Auto.child_specs(recording?: false, config: config) == []
    assert Auto.child_specs(config: %{config | enabled: false}) == []
    assert [{Auto, _opts}] = Auto.child_specs(config: config)
  end

  test "supervisor records the boot before returning", %{test: test} do
    dir = Path.join(System.tmp_dir!(), "auto-boot-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    opts = [path: Path.join(dir, "deploys.ndjson"), boot_id: to_string(test), at: ~U[2026-10-10 00:00:00Z], release_dir: nil, instance_id: nil, name: nil]
    config = %Aiur.Config.Schema.Experiments.Auto{version_line: false, release_line: false}

    start_supervised!(
      {Auto,
       name: nil,
       config: config,
       feature_opts: [name: nil, start_paused?: true, path: Path.join(dir, "features.json")],
       ledger_opts: opts,
       creator_opts: [name: nil, path: Path.join(dir, "creator.json")]}
    )

    assert {:ok, [row]} = Auto.deploys({~U[2026-10-09 00:00:00Z], ~U[2026-10-11 00:00:00Z]}, opts)
    assert row["boot_id"] == to_string(test)
    assert row["source_sha"] == nil
  end

  test "an automatic worker startup failure leaves the parent supervisor usable" do
    dir = Path.join(System.tmp_dir!(), "auto-unavailable-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    receipt = Path.join(dir, "creator.json")
    File.write!(receipt, "invalid JSON")
    ledger = [path: Path.join(dir, "deploys.ndjson"), name: nil, release_dir: nil, instance_id: nil]

    log =
      capture_log(fn ->
        assert {:ok, :undefined} = start_supervised({Auto, name: nil, ledger_opts: ledger, creator_opts: [name: nil, path: receipt]})
      end)

    assert log =~ "automatic experiments unavailable"
    assert Auto.create(%Line{source: :aiur_version, key: "auto:version:0.0.10", at: ~U[2026-10-10 00:00:00Z]}) == {:error, :unavailable}
  end
end
