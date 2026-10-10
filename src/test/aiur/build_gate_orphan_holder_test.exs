defmodule Aiur.BuildGateOrphanHolderTest do
  use ExUnit.Case, async: false

  @linux_build_gate match?({:unix, :linux}, :os.type()) and not is_nil(System.find_executable("flock"))
  @linux_only if(@linux_build_gate, do: [linux_lock: true], else: [skip: "requires Linux flock leases"])

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-holder-#{System.unique_integer([:positive])}")
    lock_dir = Path.join(root, "locks")
    File.mkdir_p!(lock_dir)
    on_exit(fn -> File.rm_rf!(root) end)
    %{lock_dir: lock_dir, release: Path.join(root, "release"), bash: System.find_executable("bash") || flunk("bash is required")}
  end

  @tag @linux_only
  test "a holder exits within one second after its lock directory is removed", context do
    holder = start_holder(context, System.pid())

    File.rm_rf!(context.lock_dir)
    assert_receive {^holder, {:exit_status, 0}}, 1_000
  end

  @tag @linux_only
  test "a holder exits within one second after its parent dies", context do
    parent = Port.open({:spawn_executable, System.find_executable("sleep")}, [:exit_status, args: ["30"]])
    {:os_pid, parent_pid} = Port.info(parent, :os_pid)
    holder = start_holder(context, Integer.to_string(parent_pid))

    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(parent_pid)])
    assert_receive {^parent, {:exit_status, _}}, 1_000
    assert_receive {^holder, {:exit_status, 0}}, 1_000
  end

  defp start_holder(context, parent_pid) do
    slot_lock = Path.join(context.lock_dir, "slot-1.lock")
    script = "exec 8<>\"$1\"\nflock 8\n"
    Aiur.BuildGateTestHolder.start!(context.bash, script, ["build-gate-holder", slot_lock], context.lock_dir, context.release, parent_pid)
  end
end
