defmodule Aiur.BuildGate.ReapingTest do
  use ExUnit.Case, async: true

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
