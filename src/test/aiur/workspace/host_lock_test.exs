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
    @tag :real_proc
    test "dead owner pid is proof only when the lock owner is stale" do
      holder = %{
        node: to_string(Node.self()),
        os_pid: 2_000_000_000,
        owner_id: "old-lock",
        acquired_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      stale_lock = %{path: Path.join(workspace_path("host-lock-missing-proof"), ".lock")}

      assert :owner_pid_dead = HostLock.dead_owner_proof(holder, to_string(Node.self()), stale_lock)

      workspace = workspace_path("host-lock-live-owner-proof")
      assert {:ok, lock} = HostLock.acquire(workspace, "24")
      assert is_binary(lock.holder.owner_started_at)
      assert {:keep, :owner_matches_daemon} = HostLock.dead_owner_proof(lock.holder, to_string(Node.self()), lock)
      assert :ok = HostLock.release(lock)

      assert {:keep, :pid_missing} = HostLock.dead_owner_proof(%{holder | os_pid: nil}, to_string(Node.self()), stale_lock)
      assert {:keep, :owner_identity_unavailable} = HostLock.dead_owner_proof(%{holder | owner_id: nil}, to_string(Node.self()), stale_lock)
    end

    test "a pid reused after the recorded owner start is treated as dead" do
      proc_root = proc_root("host-lock-reused-pid", 4242, 300)
      owner_started_at = DateTime.from_unix!(1_700_000_000_000, :millisecond) |> DateTime.to_iso8601()

      holder = %{
        node: to_string(Node.self()),
        os_pid: 4242,
        owner_id: "old-lock",
        acquired_at: DateTime.add(DateTime.from_unix!(1_700_000_000_000, :millisecond), -1, :day) |> DateTime.to_iso8601(),
        owner_started_at: owner_started_at
      }

      proof_opts = [proc_root: proc_root, clock_ticks: 100, current_os_pid: 1]
      assert :owner_pid_dead = HostLock.dead_owner_proof(holder, to_string(Node.self()), %{path: Path.join(proc_root, "missing.lock")}, proof_opts)
    end

    test "a process start within two seconds of recorded owner start remains live" do
      proc_root = proc_root("host-lock-start-time-tolerance", 4243, 100)
      owner_started_at = DateTime.from_unix!(1_700_000_000_000, :millisecond) |> DateTime.to_iso8601()
      holder = %{node: to_string(Node.self()), os_pid: 4243, owner_id: "old-lock", acquired_at: "2020-01-01T00:00:00Z", owner_started_at: owner_started_at}
      proof_opts = [proc_root: proc_root, clock_ticks: 100, current_os_pid: 1]

      assert {:keep, :start_time_within_tolerance} =
               HostLock.dead_owner_proof(holder, to_string(Node.self()), %{path: Path.join(proc_root, "missing.lock")}, proof_opts)
    end

    test "an unavailable proc root does not prove owner exit" do
      holder = %{node: to_string(Node.self()), os_pid: 2_000_000_000, owner_id: "old-lock", acquired_at: DateTime.utc_now() |> DateTime.to_iso8601()}
      proc_root = Path.join(Aiur.TestSupport.tmp_root!("host-lock-unavailable-proc"), "missing-proc")

      assert {:keep, :proc_unreadable} ==
               HostLock.dead_owner_proof(holder, to_string(Node.self()), %{path: Path.join(proc_root, "missing.lock")}, proc_root: proc_root)
    end

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
    test "a rejected guardian handoff releases the freshly acquired lock" do
      workspace = workspace_path("host-lock-rejected-handoff")
      guardian = spawn(fn -> Process.sleep(:infinity) end)
      monitor = Process.monitor(guardian)
      Process.exit(guardian, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^guardian, :killed}, 1000

      assert {:ok, lock} = HostLock.acquire(workspace, "24", alive_fun: fn _pid -> true end)

      assert {:error, :workspace_ownership_lost} =
               HostLock.handoff_to_ownership(lock, %{guardian: guardian, generation: 1})

      assert :none = HostLock.holder(workspace)
    end

    test "release never removes a lock a later owner reclaimed" do
      workspace = workspace_path("host-lock-release-safety")

      assert {:ok, stale} = HostLock.acquire(workspace, "24", os_pid: 4242, alive_fun: fn _pid -> true end)
      assert {:ok, live} = HostLock.acquire(workspace, "24", os_pid: 7777, alive_fun: fn _pid -> false end)

      assert :ok = HostLock.release(stale)
      assert {:ok, holder} = HostLock.holder(workspace)
      assert holder.owner_id == live.holder.owner_id
    end

    test "release tolerates anything that is not a lock" do
      assert :ok = HostLock.release(nil)
      assert :ok = HostLock.release(%{path: "/nonexistent/24.lock", holder: %{owner_id: "gone"}})
    end
  end

  describe "reporting an absent or damaged lock" do
    test "an unlocked workspace has no holder" do
      assert :none = HostLock.holder(workspace_path("host-lock-none"))
    end

    test "a lock whose fields are the wrong types degrades to a nameable holder" do
      workspace = workspace_path("host-lock-wrong-types")
      File.mkdir_p!(Path.dirname(workspace))
      File.write!(HostLock.lock_path(workspace), Jason.encode!(%{node: 123, os_pid: "not-a-pid"}))

      assert {:ok, holder} = HostLock.holder(workspace)
      assert holder.node == "unknown"
      assert holder.os_pid == nil
      assert holder.ticket == "unknown"

      # A pid that cannot be read names no process to probe, so the workspace
      # is not treated as live-owned.
      assert {:ok, _reclaimed} = HostLock.acquire(workspace, "24", os_pid: 7777, alive_fun: fn _pid -> true end)
    end

    test "describe/1 still produces a message for something that is not a holder" do
      assert HostLock.describe(:nothing) == "an unidentified holder"
    end
  end

  describe "the lock cannot be evaluated" do
    test "a workspace whose parent is not a directory reports unavailable, never free" do
      root = Aiur.TestSupport.tmp_root!("host-lock-enotdir")
      blocker = Path.join(root, "blocker")
      File.mkdir_p!(root)
      File.write!(blocker, "not a directory")

      assert {:error, {:workspace_lock_unavailable, _reason}} =
               HostLock.acquire(Path.join(blocker, "24"), "24")
    end

    test "an unwritable workspace parent reports unavailable, never free" do
      root = Aiur.TestSupport.tmp_root!("host-lock-eacces")
      File.mkdir_p!(root)
      File.chmod!(root, 0o500)
      on_exit(fn -> File.chmod(root, 0o700) end)

      assert {:error, {:workspace_lock_unavailable, _reason}} =
               HostLock.acquire(Path.join(root, "24"), "24")
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

  defp proc_root(name, pid, start_ticks) do
    root = Path.join(Aiur.TestSupport.tmp_root!(name), "proc")
    File.mkdir_p!(Path.join(root, "self"))
    File.mkdir_p!(Path.join(root, Integer.to_string(pid)))
    File.write!(Path.join(root, "self/stat"), proc_stat(1, 10))
    File.write!(Path.join([root, Integer.to_string(pid), "stat"]), proc_stat(pid, start_ticks))
    File.write!(Path.join(root, "stat"), "btime 1700000000\n")
    root
  end

  defp proc_stat(pid, start_ticks) do
    fields = ["S" | List.duplicate("0", 18) ++ [Integer.to_string(start_ticks)]]
    "#{pid} (fixture) #{Enum.join(fields, " ")}\n"
  end

  # A pid that has exited: spawn a trivial command, wait for it, then reuse its
  # pid. Nothing else on the host can have taken it in between within this test.
  defp dead_os_pid do
    {output, 0} = System.cmd("sh", ["-c", "echo $$"])
    output |> String.trim() |> String.to_integer()
  end
end
