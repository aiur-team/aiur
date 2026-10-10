defmodule Aiur.TestCleanupTest do
  # Mutates global :aiur application env, so it cannot run async.
  use ExUnit.Case, async: false

  alias Aiur.TestCleanup

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-test-cleanup")
    File.mkdir_p!(Path.join(root, "state"))
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "refuses to remove a directory an app env key still points into", %{root: root} do
    Application.put_env(:aiur, :test_cleanup_probe_dir, Path.join(root, "state"))
    on_exit(fn -> Application.delete_env(:aiur, :test_cleanup_probe_dir) end)

    assert_raise RuntimeError, ~r/:test_cleanup_probe_dir.* still points into it/, fn ->
      TestCleanup.rm_rf!(root)
    end

    assert File.dir?(root)

    Application.delete_env(:aiur, :test_cleanup_probe_dir)
    assert :ok = TestCleanup.rm_rf!(root)
    refute File.exists?(root)
  end

  # A read-only parent makes every removal fail deterministically; the race
  # itself loses to a live writer only a few times in hundreds of attempts.
  test "waits out a holder that lets go, where a single rm_rf fails", %{root: root} do
    File.chmod!(root, 0o500)
    assert {:error, _reason, ^root} = File.rm_rf(root)

    Task.start(fn ->
      Process.sleep(200)
      File.chmod!(root, 0o700)
    end)

    assert :ok = TestCleanup.rm_rf!(root)
    refute File.exists?(root)
  end

  test "raises when the directory never becomes removable", %{root: root} do
    File.chmod!(root, 0o500)
    on_exit(fn -> File.chmod(root, 0o700) end)

    assert_raise RuntimeError, ~r/a writer is still active/, fn -> TestCleanup.rm_rf!(root) end
    assert File.dir?(root)
  end
end
