defmodule Aiur.ShutdownTest do
  use ExUnit.Case, async: false

  alias Aiur.Shutdown

  test "cleanup/1 is a no-op on an empty registry" do
    assert Shutdown.cleanup() == :ok
  end

  test "cleanup/1 is idempotent (second call still returns :ok)" do
    assert Shutdown.cleanup(100) == :ok
    assert Shutdown.cleanup(100) == :ok
  end

  test "cleanup/1 swallows raises so the SIGTERM path can finish" do
    # Force a crash by passing a non-integer; cleanup should log + return :ok.
    assert Shutdown.cleanup(-1) == :ok
  end

  test "reap_tmp_artifacts/1 deletes only stale aiur-shaped temp entries" do
    tmp_dir = tmp_dir()
    old_ms = 1_000_000
    max_age_ms = :timer.hours(6)
    stale_mtime = div(old_ms - max_age_ms - 1_000, 1_000)
    recent_mtime = div(old_ms - 1_000, 1_000)

    stale_file = touch_tmp!(tmp_dir, "aiur-trap.123.log", stale_mtime)
    stale_dir = touch_tmp_dir!(tmp_dir, "aiur-debug", stale_mtime)
    recent_file = touch_tmp!(tmp_dir, "aiur-launcher.default.abc", recent_mtime)
    unrelated = touch_tmp!(tmp_dir, "not-aiur-trap.123.log", stale_mtime)

    assert %{deleted: 2, skipped: 0} =
             Shutdown.reap_tmp_artifacts(
               tmp_dir: tmp_dir,
               now_ms: old_ms,
               max_age_ms: max_age_ms,
               owner_uid: nil
             )

    refute File.exists?(stale_file)
    refute File.exists?(stale_dir)
    assert File.exists?(recent_file)
    assert File.exists?(unrelated)
  end

  test "reap_tmp_artifacts/1 preserves protected and wrong-owner entries" do
    tmp_dir = tmp_dir()
    now_ms = 1_000_000
    max_age_ms = :timer.hours(6)
    stale_mtime = div(now_ms - max_age_ms - 1_000, 1_000)

    protected = touch_tmp!(tmp_dir, "aiur-123-sessions", stale_mtime)
    wrong_owner = touch_tmp!(tmp_dir, "aiur-tree.123.json", stale_mtime)

    stat = File.stat!(wrong_owner, time: :posix)

    assert %{deleted: 0, skipped: 0} =
             Shutdown.reap_tmp_artifacts(
               tmp_dir: tmp_dir,
               now_ms: now_ms,
               max_age_ms: max_age_ms,
               owner_uid: stat.uid + 1,
               protected_paths: [protected]
             )

    assert File.exists?(protected)
    assert File.exists?(wrong_owner)
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "aiur-shutdown-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp touch_tmp!(tmp_dir, name, mtime) do
    path = Path.join(tmp_dir, name)
    File.write!(path, "stale")
    File.touch!(path, mtime)
    path
  end

  defp touch_tmp_dir!(tmp_dir, name, mtime) do
    path = Path.join(tmp_dir, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "log"), "stale")
    File.touch!(path, mtime)
    path
  end
end
