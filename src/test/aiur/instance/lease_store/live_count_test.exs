defmodule Aiur.Instance.LeaseStore.LiveCountTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias Aiur.Instance.LeaseStore.LiveCount

  test "persists the last roster size with owner-only permissions" do
    directory = Path.join(System.tmp_dir!(), "aiur-live-count-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "last-live-instance-count")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(directory) end)

    assert :ok = LiveCount.write_file(path, 4)
    assert LiveCount.read_file(path) == 4
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert band(mode, 0o777) == 0o600
  end

  test "an absent or invalid roster size uses the conservative two-instance divisor" do
    path = Path.join(System.tmp_dir!(), "aiur-live-count-missing-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)

    assert LiveCount.read_file(path) == 2
    assert :ok = File.write(path, "one")
    assert LiveCount.read_file(path) == 2
  end
end
