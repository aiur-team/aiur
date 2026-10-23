defmodule Aiur.Workspace.StaleGitLockTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.StaleGitLock

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-stale-git-lock")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "preserves a live lock through a symlinked workspace path", %{root: root} do
    workspace = init_repo!(Path.join(root, "workspace"))
    alias_path = Path.join(root, "workspace-alias")
    File.ln_s!(workspace, alias_path)

    lock = Path.join([workspace, ".git", "index.lock"])
    File.write!(lock, "active")
    set_stale_mtime!(lock)
    {:ok, io} = File.open(lock, [:read])

    assert {:error, {:git_metadata_lock_held, ^lock, age, 6, pid}} =
             StaleGitLock.recover(alias_path, nil)

    assert age >= 120
    assert pid == String.to_integer(System.pid())
    assert :ok = File.close(io)
    assert File.read!(lock) == "active"
  end

  test "waits for a young unheld lock to cross the stale threshold", %{root: root} do
    workspace = init_repo!(Path.join(root, "workspace"))
    lock = Path.join([workspace, ".git", "index.lock"])
    File.write!(lock, "stale")
    parent = self()

    assert :ok =
             StaleGitLock.recover(workspace, nil,
               holder_probe: fn _path -> {:ok, []} end,
               sleep: fn milliseconds ->
                 send(parent, {:waited, milliseconds})
                 set_stale_mtime!(lock)
               end
             )

    assert_received {:waited, milliseconds}
    assert milliseconds in 1..120_000
    refute File.exists?(lock)
  end

  test "ignores an unrelated same-user process with an unreadable fd directory", %{root: root} do
    workspace = init_repo!(Path.join(root, "workspace"))
    lock = Path.join([workspace, ".git", "index.lock"])
    File.write!(lock, "stale")
    set_stale_mtime!(lock)

    proc_root = Path.join(root, "proc")
    process_dir = Path.join([proc_root, "999999999"])
    fd_dir = Path.join(process_dir, "fd")
    File.mkdir_p!(fd_dir)
    File.chmod!(fd_dir, 0o000)

    try do
      assert :ok = StaleGitLock.recover(workspace, nil, proc_root: proc_root)
      refute File.exists?(lock)

      File.write!(lock, "active")
      set_stale_mtime!(lock)
      File.ln_s!(workspace, Path.join(process_dir, "cwd"))

      assert {:error, {:git_metadata_lock_held, ^lock, age, 6, 999_999_999}} =
               StaleGitLock.recover(workspace, nil, proc_root: proc_root)

      assert age >= 120
      assert File.read!(lock) == "active"
    after
      File.chmod!(fd_dir, 0o700)
    end
  end

  test "detects a workspace process even when it has closed the lock file", %{root: root} do
    workspace = init_repo!(Path.join(root, "workspace"))
    lock = Path.join([workspace, ".git", "index.lock"])
    File.write!(lock, "active")
    set_stale_mtime!(lock)
    shell = System.find_executable("sh")

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        args: ["-c", "cd #{shell_quote(workspace)} && exec sleep 5"]
      ])

    try do
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      assert {:error, {:git_metadata_lock_held, ^lock, age, 6, ^os_pid}} =
               StaleGitLock.recover(workspace, nil)

      assert age >= 120
    after
      Port.close(port)
    end
  end

  defp init_repo!(workspace) do
    File.mkdir_p!(workspace)
    {_, 0} = System.cmd("git", ["init", "--quiet", "-b", "main", workspace])
    workspace
  end

  defp set_stale_mtime!(path) do
    timestamp = DateTime.to_unix(DateTime.add(DateTime.utc_now(), -180, :second))
    {_, 0} = System.cmd("touch", ["-d", "@#{timestamp}", path])
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
