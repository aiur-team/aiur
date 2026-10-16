defmodule Aiur.AgentControlCLIBuildGateStatusTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{AgentControlCLI, BuildGate, Config, Issue, Orchestrator}

  test "status keeps namespace-unknown holders active and marks them unknown" do
    gate_dir = Aiur.TestSupport.tmp_root!("aiur-build-gate-status-unknown")
    lock_dir = BuildGate.lock_dir(gate_dir)
    previous = Application.get_env(:aiur, :build_gate_dir_override)
    release_path = Path.join(gate_dir, "holder.release")
    slot_lock = Path.join(lock_dir, "slot-1.lock")
    slot2_lock = Path.join(lock_dir, "slot-2.lock")
    slot_owner = Path.join(gate_dir, "slot-1.owner")
    slot2_owner = Path.join(gate_dir, "slot-2.owner")
    queue_path = Path.join(gate_dir, "queue/lease-v2-status")
    timeout_path = Path.join(gate_dir, "slot-1.hold-timeout")
    {:ok, pid_namespace} = File.read_link("/proc/self/ns/pid")

    gone_metadata =
      "version=2\ntoken=gone\npid=2\npgid=1\nholder_pid=2\ncommand_pgid=999999999\ncommand_pid_namespace=#{pid_namespace}\n" <>
        "phase=test\ncommand=mix test\nstarted_at=#{System.os_time(:second) - 90}\n"

    unknown_metadata =
      "version=2\ntoken=unknown\npid=2\npgid=1\nholder_pid=2\ncommand_pgid=999999999\n" <>
        "command_pid_namespace=unavailable\nphase=test\ncommand=mix test\nstarted_at=#{System.os_time(:second) - 90}\n"

    Application.put_env(:aiur, :build_gate_dir_override, gate_dir)
    assert {:ok, _canonical_gate_dir} = BuildGate.prepare_writable_root(gate_dir: gate_dir, slots: Config.max_concurrent_builds())
    File.mkdir_p!(Path.join(gate_dir, "queue"))
    File.write!(slot_owner, gone_metadata)
    File.write!(slot2_owner, unknown_metadata)
    File.write!(queue_path, gone_metadata)
    File.write!(timeout_path, "version=2\ncommand=mix test\nheld_for_seconds=3600\nreason=retained\n")

    bash = System.find_executable("bash") || flunk("bash is required for build-gate status tests")

    script = ~S"""
    exec 8<>"$1"
    flock 8
    exec 9<>"$2"
    flock 9
    exec 10<>"$3"
    flock 10
    """

    holder =
      Aiur.BuildGateTestHolder.start!(
        bash,
        script,
        ["build-gate-holder", slot_lock, queue_path, slot2_lock],
        Path.dirname(slot_lock),
        release_path
      )

    pid = Process.whereis(Orchestrator)
    original_state = :sys.get_state(pid)

    on_exit(fn ->
      File.touch!(release_path)
      if Process.alive?(pid), do: :sys.replace_state(pid, fn _state -> original_state end)
      if is_nil(previous), do: Application.delete_env(:aiur, :build_gate_dir_override), else: Application.put_env(:aiur, :build_gate_dir_override, previous)
      Aiur.TestCleanup.rm_rf!(gate_dir)
      Aiur.TestCleanup.rm_rf!(lock_dir)
    end)

    :sys.replace_state(pid, fn state ->
      issue = %Issue{id: "issue-idle", identifier: "repo#idle", state: "In Progress", title: "Idle"}
      %{state | last_polled_issues: %{"issue-idle" => issue}, max_concurrent_agents: 10}
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)
    assert output =~ "BUILD GATE 1/#{Config.max_concurrent_builds()} active, 1 held without a command, 1 queued"
    assert output =~ "(command gone)"
    assert output =~ "BUILD GATE HOLDER slot=2 pid=2 command=\"mix test\" held="
    assert output =~ "(command liveness unknown)"
    assert output =~ "BUILD GATE TIMEOUT slot=1 command=\"mix test\" held=1h0m reason=retained"

    File.touch!(release_path)
    assert_receive {^holder, {:exit_status, 0}}, 2_000
    :sys.replace_state(pid, fn _state -> original_state end)
  end
end
