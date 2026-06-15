defmodule Aiur.Logs.RetentionTest do
  use ExUnit.Case, async: true

  alias Aiur.Logs.Retention

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-retention-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # Writes a session dir holding one file of `bytes`, then stamps the dir
  # mtime AFTER the write (writing a file bumps the dir mtime to "now").
  defp make_session(root, name, bytes, mtime_secs) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "log"), :binary.copy(<<0>>, bytes))
    File.touch!(dir, mtime_secs)
    dir
  end

  defp start_sweeper(root, opts) do
    {:ok, pid} =
      Retention.start_link(Keyword.merge([root: root, name: nil, start_paused?: true], opts))

    pid
  end

  test "deletes oldest sessions first until under cap", %{root: root} do
    # Three 500KB sessions = 1.5MB against a 1MB cap; dropping just the
    # oldest brings the total to 1.0MB (≤ cap) so exactly one is reaped.
    old = make_session(root, "old", 500_000, 1_000)
    mid = make_session(root, "mid", 500_000, 2_000)
    new = make_session(root, "new", 500_000, 3_000)

    pid = start_sweeper(root, cap_mb_fun: fn -> 1 end, current_session_fun: fn -> nil end)
    result = Retention.sweep(pid)

    assert result.deleted == 1
    refute File.dir?(old)
    assert File.dir?(mid)
    assert File.dir?(new)
  end

  test "no deletions when total is under cap", %{root: root} do
    kept = make_session(root, "kept", 100_000, 1_000)

    pid = start_sweeper(root, cap_mb_fun: fn -> 1 end, current_session_fun: fn -> nil end)

    assert %{deleted: 0} = Retention.sweep(pid)
    assert File.dir?(kept)
  end

  test "never deletes the active session even if it alone exceeds cap", %{root: root} do
    # `active` is the oldest AND over cap by itself; the guard must keep
    # it and instead reap the younger sibling to claw back space.
    active = make_session(root, "active", 1_500_000, 1_000)
    other = make_session(root, "other", 100_000, 2_000)

    pid = start_sweeper(root, cap_mb_fun: fn -> 1 end, current_session_fun: fn -> active end)
    result = Retention.sweep(pid)

    assert File.dir?(active)
    refute File.dir?(other)
    assert result.deleted == 1
  end

  test "missing root is a no-op", %{root: root} do
    File.rm_rf!(root)

    pid = start_sweeper(root, cap_mb_fun: fn -> 1 end, current_session_fun: fn -> nil end)

    assert %{deleted: 0} = Retention.sweep(pid)
  end
end
