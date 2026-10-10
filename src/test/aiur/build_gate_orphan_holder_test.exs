defmodule Aiur.BuildGateOrphanHolderTest do
  use ExUnit.Case, async: false

  @linux_build_gate match?({:unix, :linux}, :os.type()) and not is_nil(System.find_executable("flock"))
  @linux_only if(@linux_build_gate, do: [linux_lock: true], else: [skip: "requires Linux flock leases"])

  @tag @linux_only
  test "a holder exits within one second after its lock directory is removed" do
    root = Path.join(System.tmp_dir!(), "aiur-holder-#{System.unique_integer([:positive])}")
    lock_dir = Path.join(root, "locks")
    release = Path.join(root, "release")
    File.mkdir_p!(lock_dir)
    slot_lock = Path.join(lock_dir, "slot-1.lock")
    bash = System.find_executable("bash") || flunk("bash is required")

    script = ~S"""
    printf 'ready\n'
    exec 8<>"$1"
    flock 8
    while [[ -d $2 && ! -e $3 ]] && kill -0 "$4" 2>/dev/null; do sleep 0.5; done
    """

    holder = Aiur.BuildGateTestHolder.start!(bash, script, ["build-gate-holder", slot_lock, lock_dir, release, System.pid()], release)

    File.rm_rf!(lock_dir)
    assert_receive {^holder, {:exit_status, 0}}, 1_000
    File.rm_rf!(root)
  end
end
