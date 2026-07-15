defmodule Aiur.CurrentRunMembership.MarkerTest do
  use ExUnit.Case, async: true

  alias Aiur.CurrentRunMembership.Store.Marker

  @run_id "marker-codec-test"

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-membership-marker-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "membership.degraded.json")}
  end

  test "writes a fixed content-free reason instead of the corrupt artifact detail", %{path: path} do
    assert :ok = File.mkdir_p(Path.dirname(path))

    assert :ok =
             Marker.write(path, @run_id, {:checkpoint_corrupt, "ghp_credential_shaped_sentinel"}, fn ->
               :ok
             end)

    assert %{"version" => 1, "run_id" => @run_id, "reason" => "checkpoint_corrupt"} =
             Jason.decode!(File.read!(path))

    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    refute File.read!(path) =~ "ghp_"
    assert {:degraded, :checkpoint_corrupt} = Marker.load(path, @run_id)
  end

  test "rejects a marker with extra content-bearing keys", %{path: path} do
    record = %{"version" => 1, "run_id" => @run_id, "reason" => "checkpoint_corrupt", "title" => "private title"}
    assert :ok = File.mkdir_p(Path.dirname(path))
    assert :ok = File.write(path, Jason.encode!(record))

    assert {:unavailable, "membership recovery marker is invalid"} = Marker.load(path, @run_id)
  end

  test "rejects a marker reason containing credential-shaped content", %{path: path} do
    record = %{"version" => 1, "run_id" => @run_id, "reason" => "ghp_credential_shaped_sentinel"}
    assert :ok = File.mkdir_p(Path.dirname(path))
    assert :ok = File.write(path, Jason.encode!(record))

    assert {:unavailable, "membership recovery marker is invalid"} = Marker.load(path, @run_id)
  end
end
