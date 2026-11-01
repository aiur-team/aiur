defmodule Aiur.BuildGate.ReapingTest do
  use ExUnit.Case, async: true

  @tag skip: :os.type() != {:unix, :linux}
  test "orphan publication files are reaped while live owner candidates survive" do
    reaper_path = Path.expand("../../../priv/build_gate_reaper.py", __DIR__)
    gate_dir = Path.join(System.tmp_dir!(), "aiur-build-gate-reaper-#{System.unique_integer([:positive])}")
    File.mkdir_p!(gate_dir)

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(gate_dir) end)

    pid = System.pid() |> String.to_integer()
    namespace = File.read_link!("/proc/#{pid}/ns/pid")
    old = System.os_time(:second) - 600

    dead_namespace_owner = Path.join(gate_dir, ".owner-v2.dead-namespace")
    dead_zero_owner = Path.join(gate_dir, ".owner-v2.zero-holder")
    live_owner = Path.join(gate_dir, ".owner-v2.live")

    File.write!(dead_namespace_owner, "pid=999999999\nholder_pid=0\ncommand_pid_namespace=pid:[999999999999]\n")
    File.write!(dead_zero_owner, "pid=0\nholder_pid=0\ncommand_pid_namespace=\n")
    File.write!(live_owner, "pid=#{pid}\nholder_pid=0\ncommand_pid_namespace=#{namespace}\n")

    handshake_paths =
      for prefix <- ~w(.command-ready-v2. .holder-started-v2. .holder-ready-v2. .command-v2. .status-v2. .status-ack-v2.),
          into: [],
          do: Path.join(gate_dir, prefix <> "orphan")

    Enum.each([dead_namespace_owner, dead_zero_owner, live_owner | handshake_paths], fn path ->
      File.touch!(path, old)
    end)

    assert {output, 0} = System.cmd("python3", [reaper_path, gate_dir, gate_dir <> ".locks"], stderr_to_stdout: true)
    assert output =~ "owners=2 handshakes=6"
    refute File.exists?(dead_namespace_owner)
    refute File.exists?(dead_zero_owner)
    assert File.regular?(live_owner)
    assert Enum.all?(handshake_paths, &(not File.exists?(&1)))
  end

  @tag skip: :os.type() != {:unix, :linux}
  test "handshake files belonging to a live slot remain available" do
    reaper_path = Path.expand("../../../priv/build_gate_reaper.py", __DIR__)
    gate_dir = Path.join(System.tmp_dir!(), "aiur-build-gate-live-reaper-#{System.unique_integer([:positive])}")
    lock_dir = gate_dir <> ".locks"
    File.mkdir_p!(gate_dir)
    File.mkdir_p!(lock_dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(gate_dir) end)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(lock_dir) end)

    probe = ~S"""
    import fcntl, os, subprocess, sys
    reaper, gate_dir, lock_dir = sys.argv[1:]
    lock_path = os.path.join(lock_dir, "slot-1.lock")
    with open(lock_path, "wb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        pid = os.getpid()
        namespace = os.readlink(f"/proc/{pid}/ns/pid")
        owner = os.path.join(gate_dir, "slot-1.owner")
        with open(owner, "w", encoding="utf-8") as file:
            file.write(f"pid={pid}\nholder_pid={pid}\ncommand_pid_namespace={namespace}\nstarted_at=1\n")
        handshake = os.path.join(gate_dir, ".status-v2.live")
        with open(handshake, "w", encoding="utf-8") as file:
            file.write("in flight\n")
        os.utime(handshake, (1, 1))
        result = subprocess.run([sys.executable, reaper, gate_dir, lock_dir], check=True)
        assert os.path.isfile(handshake), "live holder's status file was removed"
    print("live slot handshake preserved")
    """

    assert {"live slot handshake preserved\n", 0} =
             System.cmd("python3", ["-c", probe, reaper_path, gate_dir, lock_dir], stderr_to_stdout: true)
  end

  @tag skip: :os.type() != {:unix, :linux}
  test "running holder reaps 50 adopted children and preserves command exit status" do
    holder_path = Path.expand("../../../priv/build_gate_holder.py", __DIR__)

    probe = ~S"""
    import os, runpy, signal, subprocess, sys
    holder = runpy.run_path(sys.argv[1])
    holder["become_subreaper"]()
    command = r'''
    import os, time
    read_fd, write_fd = os.pipe()
    spawner = os.fork()
    if spawner == 0:
        os.close(read_fd)
        children = []
        for _ in range(50):
            pid = os.fork()
            if pid == 0:
                os._exit(0)
            children.append(pid)
        os.write(write_fd, " ".join(map(str, children)).encode())
        os._exit(0)
    os.close(write_fd)
    children = list(map(int, os.read(read_fd, 4096).split()))
    os.close(read_fd)
    os.waitpid(spawner, 0)
    assert len(children) == 50
    deadline = time.monotonic() + 5
    while any(os.path.exists(f"/proc/{pid}") for pid in children):
        if time.monotonic() >= deadline:
            remaining = [pid for pid in children if os.path.exists(f"/proc/{pid}")]
            raise AssertionError(f"unreaped adopted children while command running: {remaining}")
        time.sleep(0.01)
    os._exit(37)
    '''
    process = subprocess.Popen([sys.executable, "-c", command])
    result = holder["wait_for_command"](process, os.getpid(), None, "", "")
    assert holder["reap_exited_children"]() is False
    assert result == 37, f"command exit status lost: {result}"
    for code, expected in [("raise SystemExit(37)", 37),
                           ("import os, signal; os.kill(os.getpid(), signal.SIGTERM)", -signal.SIGTERM)]:
        process = subprocess.Popen([sys.executable, "-c", code])
        os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT)
        result = holder["wait_for_command"](process, os.getpid(), None, "", "")
        assert result == expected, f"already-exited command status lost: {result}"
    print("50 adopted children reaped; command status 37 preserved")
    """

    assert {"50 adopted children reaped; command status 37 preserved\n", 0} =
             System.cmd("python3", ["-c", probe, holder_path], stderr_to_stdout: true)
  end
end

Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.OrphanReaperIntegrationTest do
  use Aiur.TestSupport.BuildGateCase

  @tag @linux_only
  test "the first gate run clears stale owner and handshake publications", context do
    stale_at = System.os_time(:second) - 600
    owner_path = Path.join(context.gate_dir, ".owner-v2.orphan")
    handshake_path = Path.join(context.gate_dir, ".command-ready-v2.orphan")
    File.write!(owner_path, "pid=999999999\nholder_pid=0\ncommand_pid_namespace=pid:[999999999999]\n")
    File.write!(handshake_path, "ready\n")
    File.touch!(owner_path, stale_at)
    File.touch!(handshake_path, stale_at)

    assert {output, 0} = run_bash("mix compile", context)
    refute File.exists?(owner_path)
    refute File.exists?(handshake_path)
    refute output =~ "orphan_reaper_failed"
  end
end
