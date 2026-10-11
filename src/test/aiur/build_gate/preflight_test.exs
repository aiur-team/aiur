Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.PreflightTest do
  use Aiur.TestSupport.BuildGateCase

  test "preflight reports a real read-only Linux gate root" do
    if match?({:unix, :linux}, :os.type()) and File.dir?("/sys/kernel") do
      gate_dir = Path.join("/sys/kernel", "aiur-build-gate-#{System.unique_integer([:positive])}")

      assert {:error, {:build_gate_unavailable, details}} =
               BuildGate.prepare_writable_root(gate_dir: gate_dir, slots: 2)

      assert %{operation: :create_directory, path: ^gate_dir, reason: reason, recovery: recovery} = details

      assert reason in [:eacces, :eperm, :erofs]
      assert recovery =~ "repair"
    end
  end

  test "preflight rejects a lock namespace overlapping any effective writable root", context do
    writable_root = Path.dirname(context.gate_dir)
    assert {:ok, canonical_root} = Aiur.PathSafety.canonicalize(writable_root)

    assert {:error, {:build_gate_unavailable, details}} =
             BuildGate.prepare_writable_root(
               gate_dir: context.gate_dir,
               lock_dir: context.lock_dir,
               writable_roots: [writable_root],
               slots: 2
             )

    assert %{
             operation: :separate_lock_namespace,
             path: lock_dir,
             reason: {:overlaps_writable_root, ^canonical_root}
           } = details

    assert lock_dir == context.lock_dir
  end

  test "preflight succeeds with one unresolvable and one valid writable root, warning about the bad one",
       context do
    # Create a mode-000 directory; PathSafety.canonicalize fails with :eacces on
    # any child of it. Use gate_dir as the valid root (no overlap with lock_dir).
    restricted = Path.join(System.tmp_dir!(), "aiur-restricted-#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}")
    File.mkdir!(restricted)
    File.chmod!(restricted, 0o000)

    on_exit(fn ->
      File.chmod(restricted, 0o700)
      File.rm_rf(restricted)
    end)

    valid_root = context.gate_dir
    bad_root = Path.join(restricted, "subpath")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _canonical_gate_dir} =
                 BuildGate.prepare_writable_root(
                   gate_dir: context.gate_dir,
                   lock_dir: context.lock_dir,
                   writable_roots: [bad_root, valid_root],
                   slots: 2
                 )
      end)

    assert log =~ "build_gate skipped_unresolvable_writable_root"
    assert log =~ bad_root
  end

  test "preflight fails when all writable roots are unresolvable", context do
    # Create a mode-000 directory so PathSafety.canonicalize fails with :eacces
    # on any path rooted inside it.
    restricted = Path.join(System.tmp_dir!(), "aiur-restricted-#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}")
    File.mkdir!(restricted)
    File.chmod!(restricted, 0o000)

    on_exit(fn ->
      File.chmod(restricted, 0o700)
      File.rm_rf(restricted)
    end)

    bad_root_a = Path.join(restricted, "a")
    bad_root_b = Path.join(restricted, "b")

    assert {:error, {:build_gate_unavailable, details}} =
             BuildGate.prepare_writable_root(
               gate_dir: context.gate_dir,
               lock_dir: context.lock_dir,
               writable_roots: [bad_root_a, bad_root_b],
               slots: 2
             )

    assert %{operation: :canonicalize_writable_root} = details
  end

  test "preflight rejects a lock namespace overlapping an effective writable root, even with unresolvable roots in the list",
       context do
    # Create a mode-000 directory so one root genuinely fails canonicalization.
    restricted = Path.join(System.tmp_dir!(), "aiur-restricted-#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}")
    File.mkdir!(restricted)
    File.chmod!(restricted, 0o000)

    on_exit(fn ->
      File.chmod(restricted, 0o700)
      File.rm_rf(restricted)
    end)

    # valid_root is /tmp — it overlaps the lock_dir which lives under /tmp.
    valid_root = Path.dirname(context.gate_dir)
    bad_root = Path.join(restricted, "subpath")
    assert {:ok, canonical_root} = Aiur.PathSafety.canonicalize(valid_root)

    assert {:error, {:build_gate_unavailable, details}} =
             BuildGate.prepare_writable_root(
               gate_dir: context.gate_dir,
               lock_dir: context.lock_dir,
               writable_roots: [bad_root, valid_root],
               slots: 2
             )

    assert %{
             operation: :separate_lock_namespace,
             path: lock_dir,
             reason: {:overlaps_writable_root, ^canonical_root}
           } = details

    assert lock_dir == context.lock_dir
  end

  test "an unavailable gate directory fails closed without running Mix", context do
    invalid_gate_dir = Path.join(context.gate_dir, "not-a-directory")
    File.write!(invalid_gate_dir, "regular file")

    Enum.each(["auto", "pid"], fn strategy ->
      assert {output, 125} =
               run_bash(
                 "mix compile",
                 Map.merge(context, %{
                   gate_dir: invalid_gate_dir,
                   lease_strategy: strategy,
                   started_path: ""
                 })
               )

      assert output =~ "aiur_build_gate gate_error reason=directory_unavailable"
      assert output =~ "recovery=repair_gate_or_disable_all_build_admission"
      assert output =~ "build_start_stagger_seconds_0"
      assert output =~ "min_free_memory_mb_unset"
    end)

    refute File.exists?(context.log_path)
  end

  test "missing Linux flock support fails closed without running Mix", context do
    command = ~S"""
    type() {
      if [[ ${1:-} == -P && ${2:-} == flock ]]; then
        return 1
      fi

      builtin type "$@"
    }

    mix compile
    """

    assert {output, 125} =
             run_bash(
               command,
               Map.merge(context, %{lease_strategy: "linux", started_path: ""})
             )

    assert output =~ "aiur_build_gate gate_error reason=flock_unavailable"
    assert output =~ "recovery=repair_gate_or_disable_all_build_admission"
    refute File.exists?(context.log_path)
  end

  @tag @linux_only
  test "missing Linux subreaper runtime fails closed without running Mix", context do
    command = ~S"""
    type() {
      if [[ ${1:-} == -P && ${2:-} == python3 ]]; then
        return 1
      fi

      builtin type "$@"
    }

    mix compile
    """

    assert {output, 125} =
             run_bash(
               command,
               Map.merge(context, %{lease_strategy: "linux", started_path: ""})
             )

    assert output =~ "aiur_build_gate gate_error reason=lease_holder_runtime_unavailable"
    refute File.exists?(context.log_path)
  end

  @tag @linux_only
  test "publishes a complete numbered-slot owner record atomically", context do
    command = Task.async(fn -> run_bash("mix test", Map.put(context, :sleep_seconds, 2)) end)
    wait_for_file!(context.started_path)

    slot_path = Path.join(context.lock_dir, "slot-1.lock")
    owner_path = Path.join(context.gate_dir, "slot-1.owner")
    assert File.regular?(slot_path)
    assert File.regular?(owner_path)
    wait_for_file_contents!(owner_path, ~r/command_pgid=[1-9][0-9]*/)

    owner_pattern =
      ~r/^version=2\n
      token=.+\n
      pid=[1-9][0-9]*\n
      pgid=[0-9]+\n
      holder_pid=[1-9][0-9]*\n
      command_pgid=[1-9][0-9]*\n
      phase=test\n
      command=test\n
      started_at=[0-9]+\n$/x

    assert File.read!(owner_path) =~ owner_pattern

    assert {_output, 0} = Task.await(command, 5_000)
    assert File.exists?(slot_path)
    refute File.exists?(owner_path)
  end

  @tag @linux_only
  test "rejects a directory-shaped numbered-slot owner destination", context do
    owner_path = Path.join(context.gate_dir, "slot-1.owner")
    File.mkdir_p!(owner_path)

    assert {output, 125} = run_bash("mix compile", Map.put(context, :started_path, ""))

    assert output =~ "aiur_build_gate gate_error reason=owner_destination_invalid"
    assert File.dir?(owner_path)
    assert File.ls!(owner_path) == []
    refute File.exists?(context.log_path)
    assert Path.wildcard(Path.join(context.gate_dir, ".owner-v2.*")) == []
    assert Path.wildcard(Path.join(context.gate_dir, "queue/lease-v2-*")) == []
  end

  test "times out without running Mix while every slot has a live owner", context do
    slot_path = Path.join(context.gate_dir, "slot-1")
    File.mkdir_p!(slot_path)
    File.write!(Path.join(slot_path, "owner"), "pid=#{System.pid()}\n")

    assert {output, 124} =
             run_bash(
               "mix compile",
               Map.merge(context, %{timeout_seconds: 0, lease_strategy: "pid"})
             )

    assert output =~ "aiur_build_gate timeout"
    refute File.exists?(context.log_path)
  end

  test "reclaims a stale owner before running a later verification command", context do
    slot_path = Path.join(context.gate_dir, "slot-1")
    File.mkdir_p!(slot_path)
    File.write!(Path.join(slot_path, "owner"), "pid=999999999\n")

    assert {output, 0} = run_bash("mix compile", Map.put(context, :lease_strategy, "pid"))
    assert output =~ "aiur_build_gate stale_owner_recovered slot=1 owner_pid=999999999"
    assert File.read!(context.log_path) == "compile\n"
  end

  test "reclaims an interrupted numbered-slot owner publication", context do
    slot_path = Path.join(context.gate_dir, "slot-1")
    File.mkdir_p!(slot_path)
    File.write!(Path.join(slot_path, "owner"), "pid=")

    assert {output, 0} = run_bash("mix compile", Map.put(context, :lease_strategy, "pid"))
    assert output =~ "aiur_build_gate stale_owner_recovered slot=1 owner_pid=unknown"
    assert File.read!(context.log_path) == "compile\n"
  end

  test "keeps a slot while a dead owner's process group still has a child", context do
    command = """
    setsid bash -c 'sleep 2 &' &
    owner_pid=$!
    wait "$owner_pid"
    printf 'pid=%s\npgid=%s\ncommand=test\n' "$owner_pid" "$owner_pid" > "#{context.gate_dir}/slot-1"
    mix compile
    """

    assert {output, 124} =
             run_bash(
               command,
               Map.merge(context, %{timeout_seconds: 0, lease_strategy: "pid"})
             )

    assert output =~ "aiur_build_gate timeout"
    refute output =~ "stale_owner_recovered"
    refute File.exists?(context.log_path)
  end

  test "defers below the memory floor and resumes after MemAvailable recovers", context do
    write_meminfo!(context, 1_024)

    command =
      Task.async(fn ->
        run_bash(
          "mix compile",
          Map.merge(context, %{min_free_memory_mb: 2_048, timeout_seconds: 5})
        )
      end)

    assert Task.yield(command, 250) == nil
    refute File.exists?(context.started_path)

    write_meminfo!(context, 3_072)

    assert {output, 0} = Task.await(command, 5_000)
    assert output =~ "aiur_perf memory_hold surface=build available_mb=1024 threshold_mb=2048"
    assert File.read!(context.log_path) == "compile\n"
  end

  test "admits a build at the exact memory floor", context do
    write_meminfo!(context, 2_048)

    assert {output, 0} =
             run_bash("mix compile", Map.put(context, :min_free_memory_mb, 2_048))

    refute output =~ "aiur_perf memory_hold"
    assert File.read!(context.log_path) == "compile\n"
  end

  test "memory-only mode remains active when build-slot capacity is zero", context do
    write_meminfo!(context, 512)

    assert {output, 124} =
             run_bash(
               "mix compile",
               Map.merge(context, %{
                 slots: 0,
                 min_free_memory_mb: 1_024,
                 timeout_seconds: 0
               })
             )

    assert output =~ "aiur_perf memory_hold surface=build available_mb=512 threshold_mb=1024"
    refute File.exists?(context.log_path)
  end

  test "fails open when MemAvailable cannot be read", context do
    missing = Path.join(context.gate_dir, "missing-meminfo")

    assert {output, 0} =
             run_bash(
               "mix compile",
               Map.merge(context, %{
                 meminfo_path: missing,
                 min_free_memory_mb: 2_048
               })
             )

    assert output =~ "aiur_perf memory_unavailable surface=build action=fail_open"
    assert File.read!(context.log_path) == "compile\n"
  end
end
