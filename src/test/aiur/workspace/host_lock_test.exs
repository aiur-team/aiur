defmodule Aiur.Workspace.HostLockTest do
  use Aiur.TestSupport

  alias Aiur.Workspace.HostLock

  describe "exclusion" do
    test "a second acquirer is refused while the first holds the lock" do
      workspace = workspace_path("host-lock-exclusive")

      assert {:ok, first} = HostLock.acquire(workspace, "24", alive_fun: fn _pid -> true end)

      assert {:error, {:workspace_locked, holder}} =
               HostLock.acquire(workspace, "24", alive_fun: fn _pid -> true end)

      assert holder.owner_id == first.holder.owner_id

      # Releasing the real holder frees the workspace again, so the refusal is
      # exclusion and not a permanent poison.
      assert :ok = HostLock.release(first)
      assert {:ok, _second} = HostLock.acquire(workspace, "24", alive_fun: fn _pid -> true end)
    end

    test "the refusal names the holder's node and pid" do
      workspace = workspace_path("host-lock-names-holder")

      assert {:ok, _first} =
               HostLock.acquire(workspace, "24",
                 node: "aiur-everdred-693f8655dd@host",
                 os_pid: 4242,
                 alive_fun: fn _pid -> true end
               )

      assert {:error, {:workspace_locked, holder}} =
               HostLock.acquire(workspace, "24", alive_fun: fn _pid -> true end)

      assert holder.node == "aiur-everdred-693f8655dd@host"
      assert holder.os_pid == 4242
      assert holder.ticket == "24"

      description = HostLock.describe(holder)
      assert description =~ "aiur-everdred-693f8655dd@host"
      assert description =~ "4242"
      assert description =~ "24"
    end

    test "a live holder is honoured even when it is a different daemon on the same host" do
      workspace = workspace_path("host-lock-other-daemon")

      assert {:ok, _first} =
               HostLock.acquire(workspace, "24", node: "aiur-everdred-539163312d@host", os_pid: 4242, alive_fun: fn _pid -> true end)

      probed = :counters.new(1, [])

      assert {:error, {:workspace_locked, _holder}} =
               HostLock.acquire(workspace, "24",
                 node: "aiur-everdred-693f8655dd@host",
                 os_pid: 7777,
                 alive_fun: fn pid ->
                   :counters.add(probed, 1, pid)
                   true
                 end
               )

      assert :counters.get(probed, 1) == 4242
    end
  end

  describe "stale locks" do
    test "a lock whose owning pid is dead is reclaimed" do
      workspace = workspace_path("host-lock-stale")

      assert {:ok, _crashed} =
               HostLock.acquire(workspace, "24", node: "aiur-crashed@host", os_pid: 4242, alive_fun: fn _pid -> true end)

      assert {:ok, reclaimed} =
               HostLock.acquire(workspace, "24", node: "aiur-fresh@host", os_pid: 7777, alive_fun: fn _pid -> false end)

      assert reclaimed.holder.node == "aiur-fresh@host"
      assert {:ok, %{node: "aiur-fresh@host", os_pid: 7777}} = HostLock.holder(workspace)
    end

    test "a genuinely dead pid is reclaimed through the real liveness probe" do
      workspace = workspace_path("host-lock-real-pid")
      dead_pid = dead_os_pid()

      assert {:ok, _crashed} = HostLock.acquire(workspace, "24", os_pid: dead_pid, alive_fun: fn _pid -> true end)
      assert {:ok, reclaimed} = HostLock.acquire(workspace, "24", os_pid: 7777)
      assert reclaimed.holder.os_pid == 7777
    end

    test "an unreadable lock names nobody, so it is reclaimed rather than stranding the workspace" do
      workspace = workspace_path("host-lock-corrupt")
      File.mkdir_p!(Path.dirname(workspace))
      File.write!(HostLock.lock_path(workspace), "not json at all")

      assert {:ok, reclaimed} = HostLock.acquire(workspace, "24", os_pid: 7777, alive_fun: fn _pid -> true end)
      assert reclaimed.holder.os_pid == 7777
    end
  end

  describe "release" do
    test "release never removes a lock a later owner reclaimed" do
      workspace = workspace_path("host-lock-release-safety")

      assert {:ok, stale} = HostLock.acquire(workspace, "24", os_pid: 4242, alive_fun: fn _pid -> true end)
      assert {:ok, live} = HostLock.acquire(workspace, "24", os_pid: 7777, alive_fun: fn _pid -> false end)

      assert :ok = HostLock.release(stale)
      assert {:ok, holder} = HostLock.holder(workspace)
      assert holder.owner_id == live.holder.owner_id
    end
  end

  describe "acquire_for_issue" do
    test "locks the layout-derived workspace for a local run" do
      root = Aiur.TestSupport.tmp_root!("host-lock-issue-root")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "aiur-team/architecture-docs",
        workspace_root: root
      )

      assert {:ok, lock} = HostLock.acquire_for_issue("24", nil, alive_fun: fn _pid -> true end)
      assert lock.workspace == Path.join([root, "aiur-team", "architecture-docs", "24"])

      assert {:error, {:workspace_locked, _holder}} =
               HostLock.acquire_for_issue("24", nil, alive_fun: fn _pid -> true end)
    end

    test "a remote worker host has no local workspace to lock" do
      assert :not_applicable = HostLock.acquire_for_issue("24", "worker-1")
    end
  end

  defp workspace_path(name) do
    Path.join(Aiur.TestSupport.tmp_root!(name), "24")
  end

  # A pid that has exited: spawn a trivial command, wait for it, then reuse its
  # pid. Nothing else on the host can have taken it in between within this test.
  defp dead_os_pid do
    {output, 0} = System.cmd("sh", ["-c", "echo $$"])
    output |> String.trim() |> String.to_integer()
  end
end
