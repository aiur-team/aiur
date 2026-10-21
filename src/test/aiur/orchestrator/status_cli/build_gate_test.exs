Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliBuildGateTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{BuildGate, Config, Issue}

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  setup context do
    TestFixture.setup(context)
  end

  alias Aiur.Orchestrator.StatusCLI, as: AgentControlCLI

  test "status reports active build-gate contention", %{orchestrator: pid} do
    gate_dir = Aiur.TestSupport.tmp_root!("aiur-build-gate-status")
    lock_dir = BuildGate.lock_dir(gate_dir)
    previous = Application.get_env(:aiur, :build_gate_dir_override)
    release_path = Path.join(gate_dir, "holder.release")
    slot_lock = Path.join(lock_dir, "slot-1.lock")
    slot_owner = Path.join(gate_dir, "slot-1.owner")
    queue_path = Path.join(gate_dir, "queue/lease-v2-status")

    metadata =
      "version=2\ntoken=status\npid=2\npgid=1\nphase=test\ncommand=test\n" <>
        "started_at=#{System.os_time(:second) - 90}\n"

    Application.put_env(:aiur, :build_gate_dir_override, gate_dir)

    slots = Config.max_concurrent_builds()
    assert {:ok, _canonical_gate_dir} = BuildGate.prepare_writable_root(gate_dir: gate_dir, slots: slots)
    File.mkdir_p!(Path.join(gate_dir, "queue"))
    File.write!(slot_owner, metadata)
    File.write!(queue_path, metadata)

    bash = System.find_executable("bash") || flunk("bash is required for build-gate status tests")

    script = ~S"""
    exec 8<>"$1"
    flock 8
    exec 9<>"$2"
    flock 9
    """

    holder = Aiur.BuildGateTestHolder.start!(bash, script, ["build-gate-holder", slot_lock, queue_path], Path.dirname(slot_lock), release_path)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :build_gate_dir_override)
      else
        Application.put_env(:aiur, :build_gate_dir_override, previous)
      end

      Aiur.TestCleanup.rm_rf!(gate_dir)
      Aiur.TestCleanup.rm_rf!(lock_dir)
    end)

    assert %{active: 1, queued: 1} = BuildGate.status()

    # Pin the cap this test asserts. The checked-in fixture config sets none, so
    # the orchestrator boots with the host-core default and the `0/10` assertion
    # only ever passed by inheriting an earlier test's state.
    :sys.replace_state(pid, fn state ->
      issue = %Issue{id: "issue-idle", identifier: "repo#idle", state: "In Progress", title: "Idle"}
      %{state | last_polled_issues: %{"issue-idle" => issue}, max_concurrent_agents: 10, effective_concurrent_agents: 2}
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)
    assert output =~ ~r/AGENTS 0\/10 \(binding: awaiting dispatch; ceiling: AIMD envelope \d+\)/
    assert output =~ "BUILD GATE 1/#{Config.max_concurrent_builds()} active, 1 queued"
    assert output =~ "BUILD GATE HOLDER slot=1 pid=2 phase=test command=\"test\" held="
    assert output =~ "(lease locked)"
    assert output =~ "BUILD GATE QUEUED pid=2 phase=test command=\"test\" waiting="
    File.touch!(release_path)
    assert_receive {^holder, {:exit_status, 0}}, 2_000
  end

  test "status reports actionable legacy build-gate degradation" do
    gate_dir = Aiur.TestSupport.tmp_root!("aiur-build-gate-legacy")
    lock_dir = BuildGate.lock_dir(gate_dir)
    previous = Application.get_env(:aiur, :build_gate_dir_override)
    legacy_path = Path.join(gate_dir, "slot-1")

    Application.put_env(:aiur, :build_gate_dir_override, gate_dir)

    slots = Config.max_concurrent_builds()
    assert {:ok, _canonical_gate_dir} = BuildGate.prepare_writable_root(gate_dir: gate_dir, slots: slots)
    File.write!(legacy_path, "pid=2\npgid=1\ncommand=test\n")

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :build_gate_dir_override)
      else
        Application.put_env(:aiur, :build_gate_dir_override, previous)
      end

      Aiur.TestCleanup.rm_rf!(gate_dir)
      Aiur.TestCleanup.rm_rf!(lock_dir)
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)
    assert output =~ "BUILD GATE DEGRADED 0/#{Config.max_concurrent_builds()} active, 0 queued"
    assert output =~ "reason=legacy_state path=#{legacy_path}"
    assert output =~ "recovery=check the build-gate holder metadata"
  end
end
