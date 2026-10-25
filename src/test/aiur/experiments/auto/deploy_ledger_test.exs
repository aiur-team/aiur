defmodule Aiur.Experiments.Auto.DeployLedgerTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Auto.DeployLedger

  setup do
    dir = Path.join(System.tmp_dir!(), "deploy-ledger-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{dir: dir, opts: [path: Path.join(dir, "deploys.ndjson"), at: ~U[2026-10-10 00:00:00Z], aiur_version: "0.0.10-nightly.abc", release_dir: nil, instance_id: nil]}
  end

  test "two boots append in order and supervisor restart does not append again", %{opts: opts} do
    assert {:ok, first} = DeployLedger.record_boot(Keyword.put(opts, :boot_id, "first"))
    assert first["source_sha"] == nil
    assert first["dirty"] == nil
    assert first["base_version"] == "0.0.10"
    assert {:ok, second} = DeployLedger.record_boot(Keyword.put(opts, :boot_id, "second"))
    assert {:ok, ^second} = DeployLedger.record_boot(Keyword.put(opts, :boot_id, "second"))
    assert {:ok, ^first} = DeployLedger.previous(Keyword.put(opts, :boot_id, "second"))
    assert {:ok, nil} = DeployLedger.previous(Keyword.put(opts, :boot_id, "first"))
    assert {:ok, [^first, ^second]} = DeployLedger.list({~U[2026-10-09 00:00:00Z], ~U[2026-10-11 00:00:00Z]}, opts)
    assert {:ok, []} = DeployLedger.list({~U[2026-10-10 00:00:01Z], ~U[2026-10-11 00:00:00Z]}, opts)
  end

  test "truncated tail is skipped and repaired before the next append", %{opts: opts} do
    assert {:ok, first} = DeployLedger.record_boot(Keyword.put(opts, :boot_id, "first"))
    File.write!(opts[:path], "{\"boot_id\":", [:append])
    assert {:ok, ^first} = DeployLedger.previous(Keyword.put(opts, :boot_id, "second"))
    assert {:ok, second} = DeployLedger.record_boot(Keyword.put(opts, :boot_id, "second"))
    assert {:ok, [^first, ^second]} = DeployLedger.list({~U[2026-10-09 00:00:00Z], ~U[2026-10-11 00:00:00Z]}, opts)
  end

  test "boot reads stamp from the selected release and retains only the latest 5000 rows", %{dir: dir, opts: opts} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "AIUR_BUILD_STAMP"), "source_sha=abc\ndirty=no\n")
    rows = for n <- 1..5000, do: Jason.encode!(%{"boot_id" => to_string(n), "at" => "2026-10-10T00:00:00Z"}) <> "\n"
    File.write!(opts[:path], rows)
    assert {:ok, row} = DeployLedger.record_boot(Keyword.merge(opts, boot_id: "5001", release_dir: dir))
    assert row["source_sha"] == "abc"
    assert row["dirty"] == false
    assert {:ok, rows} = DeployLedger.list({~U[2026-10-09 00:00:00Z], ~U[2026-10-11 00:00:00Z]}, opts)
    assert length(rows) == 5000
    assert hd(rows)["boot_id"] == "2"
    assert List.last(rows)["boot_id"] == "5001"
  end

  test "existing boot retries retention after an interrupted cap", %{dir: dir, opts: opts} do
    File.mkdir_p!(dir)
    rows = for n <- 1..5001, do: Jason.encode!(%{"boot_id" => to_string(n), "at" => "2026-10-10T00:00:00Z"}) <> "\n"
    File.write!(opts[:path], rows)
    assert {:ok, %{"boot_id" => "5001"}} = DeployLedger.record_boot(Keyword.put(opts, :boot_id, "5001"))
    assert {:ok, rows} = DeployLedger.list({~U[2026-10-09 00:00:00Z], ~U[2026-10-11 00:00:00Z]}, opts)
    assert length(rows) == 5000
    assert hd(rows)["boot_id"] == "2"
    assert List.last(rows)["boot_id"] == "5001"
  end

  test "interior corruption is reported without discarding evidence", %{dir: dir, opts: opts} do
    File.mkdir_p!(dir)
    File.write!(opts[:path], "garbage\n")
    assert {:error, {:corrupt, 1, _reason}} = DeployLedger.record_boot(Keyword.put(opts, :boot_id, "new"))
    assert File.read!(opts[:path]) == "garbage\n"
  end
end
