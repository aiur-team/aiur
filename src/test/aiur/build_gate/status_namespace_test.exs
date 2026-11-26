Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.StatusNamespaceTest do
  use Aiur.TestSupport.BuildGateCase

  @tag @linux_only
  test "counts a live process group in an unprivileged PID namespace", context do
    if user_namespaces_supported?() do
      assert_namespaced_group(context, :live)
    end
  end

  # Future regression guard: the lease holder can keep the namespace alive after its command exits.
  @tag @linux_only
  test "reports an exited process group while its PID namespace remains alive", context do
    if user_namespaces_supported?() do
      assert_namespaced_group(context, :exited)
    end
  end

  defp user_namespaces_supported? do
    unshare = System.find_executable("unshare") || flunk("unshare is required")

    case System.cmd(unshare, ["--user", "--map-root-user", "--pid", "--fork", "true"], stderr_to_stdout: true) do
      {_output, 0} ->
        true

      {output, status} ->
        IO.puts("SKIP user PID namespace tests: unprivileged user namespaces unavailable (#{status}: #{String.trim(output)})")
        false
    end
  end

  defp assert_namespaced_group(context, mode) do
    gate_dir = context.gate_dir
    slot_lock = Path.join(context.lock_dir, "slot-1.lock")
    owner_path = Path.join(gate_dir, "slot-1.owner")
    ready_path = Path.join(gate_dir, "namespace-holder.ready")
    exited_path = Path.join(gate_dir, "namespace-holder.exited")
    release_path = Path.join(gate_dir, "namespace-holder.release")
    script_path = Path.join(gate_dir, "namespace-holder.py")

    File.write!(
      script_path,
      """
      import fcntl, os, sys, time

      mode, lock_path, owner_path, ready_path, exited_path, release_path = sys.argv[1:]
      lock_fd = os.open(lock_path, os.O_RDWR)
      fcntl.flock(lock_fd, fcntl.LOCK_EX)
      command_pid_path = ready_path + ".pgid"
      command_pid = os.fork()
      if command_pid == 0:
          os.setsid()
          with open(command_pid_path, "w") as pid_file:
              pid_file.write(str(os.getpgrp()))
          if mode == "exited":
              open(exited_path, "w").close()
              os._exit(0)
          while not os.path.exists(release_path):
              time.sleep(0.02)
          os._exit(0)
      while not os.path.exists(command_pid_path):
          time.sleep(0.01)
      command_pgid = int(open(command_pid_path).read())
      if mode == "exited":
          os.waitpid(command_pid, 0)
      with open(owner_path, "w") as owner:
          owner.write(
              f"version=2\\ntoken=nested\\npid={os.getpid()}\\npgid=1\\n"
              f"holder_pid={os.getpid()}\\ncommand_pgid={command_pgid}\\n"
              f"command_pid_namespace={os.readlink('/proc/self/ns/pid')}\\n"
              "phase=test\\ncommand=mix test\\n"
          )
      open(ready_path, "w").close()
      while not os.path.exists(release_path):
          time.sleep(0.02)
      if mode == "live":
          os.waitpid(command_pid, 0)
      """
    )

    bash = System.find_executable("bash") || flunk("bash is required")

    holder =
      Aiur.BuildGateTestHolder.start!(
        bash,
        ~S"""
        unshare --user --map-root-user --pid --fork sh -c 'python3 "$@"' sh "$1" "$6" "$2" "$3" "$4" "$7" "$5" &
        while [[ ! -e $4 ]]; do sleep 0.02; done
        """,
        ["build-gate-nested-holder", script_path, slot_lock, owner_path, ready_path, release_path, Atom.to_string(mode), exited_path],
        context.lock_dir,
        release_path
      )

    assert File.exists?(ready_path)

    case mode do
      :live ->
        assert %{active: 1, holders: [%{command_alive?: true}]} =
                 build_gate_status(gate_dir: gate_dir, capacity: 1)

      :exited ->
        assert File.exists?(exited_path)
        Process.sleep(100)

        assert %{active: 1, holders: [%{command_alive?: false}]} =
                 build_gate_status(gate_dir: gate_dir, capacity: 1)
    end

    File.touch!(release_path)
    assert_receive {^holder, {:exit_status, 0}}, 2_000
  end
end
