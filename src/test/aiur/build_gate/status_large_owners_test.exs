Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.StatusLargeOwnersTest do
  use Aiur.TestSupport.BuildGateCase

  @tag @linux_only
  test "reads multiple large locked owners within the aggregate scan budget", context do
    capacity = 8
    bash = System.find_executable("bash") || flunk("bash is required")
    release_path = Path.join(context.gate_dir, "large-owners.release")

    assert {:ok, _gate_dir} =
             BuildGate.prepare_writable_root(gate_dir: context.gate_dir, lock_dir: context.lock_dir, slots: capacity)

    holder_script = ~S"""
    for slot in $(seq 1 8); do
      lock="$1/slot-$slot.lock"
      exec {lock_fd}<>"$lock"
      flock "$lock_fd"
    done
    """

    holder =
      Aiur.BuildGateTestHolder.start!(
        bash,
        holder_script,
        ["build-gate-holder", context.lock_dir],
        context.lock_dir,
        release_path
      )

    command = "mix test " <> String.duplicate("test/aiur/build_gate/", 2_000)

    for slot <- 1..capacity do
      owner_path = Path.join(context.gate_dir, "slot-#{slot}.owner")

      File.write!(
        owner_path,
        "version=2\ntoken=large-#{slot}\npid=987654321\npgid=987654321\n" <>
          "holder_pid=987654321\ncommand_pgid=987654321\nphase=test\ncommand=#{command}\n"
      )
    end

    status = BuildGate.status(gate_dir: context.gate_dir, lock_dir: context.lock_dir, capacity: capacity)

    assert status.active == capacity
    refute Map.get(status, :degraded?, false)
    holders = status.holders
    assert length(holders) == capacity
    assert Enum.all?(holders, &(&1.command =~ "legacy arguments truncated"))

    File.touch!(release_path)
    assert_receive {^holder, {:exit_status, 0}}, 2_000
  end
end
