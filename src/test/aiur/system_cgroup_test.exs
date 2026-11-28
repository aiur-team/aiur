defmodule Aiur.SystemCgroupTest do
  use ExUnit.Case, async: false

  alias Aiur.SystemCgroup

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-cgroup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:aiur, :cgroup_root_override)
    assert is_binary(previous)
    refute File.exists?(previous)
    Application.put_env(:aiur, :cgroup_root_override, root)

    on_exit(fn ->
      restore_app_env(:cgroup_root_override, previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "reads finite CPU quota, using the quota pressure file", %{root: root} do
    write!(root, "cpu.max", "200000 100000")
    write!(root, "cpu.pressure", "some avg10=44.0 avg60=32.0 avg300=20.0 total=10\n")

    assert SystemCgroup.cpu_quota() == 2.0
    assert SystemCgroup.cpu_pressure() == %{avg10: 44.0, avg60: 32.0}
  end

  test "unlimited or malformed CPU quota is unavailable", %{root: root} do
    write!(root, "cpu.max", "max 100000")
    assert SystemCgroup.cpu_quota() == :unavailable
    write!(root, "cpu.max", "broken")
    assert SystemCgroup.cpu_quota() == :unavailable
  end

  test "reads cgroup memory usage, inactive file and finite memory max", %{root: root} do
    write!(root, "memory.current", "850")
    write!(root, "memory.max", "1000")
    write!(root, "memory.stat", "anon 650\ninactive_file 200\n")
    assert SystemCgroup.memory() == %{current: 850, inactive_file: 200, max: 1000}
    assert SystemCgroup.memory_max_bytes() == 1000
    write!(root, "memory.max", "max")
    assert SystemCgroup.memory() == :unavailable
    assert SystemCgroup.memory_max_bytes() == :unavailable
  end

  test "reads Aiur slice pressure and the tighter memory limit from a descendant cgroup", %{root: root} do
    slice = Path.join(root, "aiur.slice")
    worker = Path.join(slice, "worker.scope")
    File.mkdir_p!(worker)
    Application.put_env(:aiur, :cgroup_root_override, worker)

    write!(slice, "cpu.max", "max 100000")
    write!(slice, "cpu.pressure", "some avg10=2.0 avg60=0.0 avg300=0.0 total=10")
    write!(slice, "memory.high", "900")
    write!(slice, "memory.max", "1000")
    write!(slice, "memory.stat", "inactive_file 200")

    write!(slice, "memory.current", "925")
    assert SystemCgroup.dispatch_headroom(10.0, 0.8) == :pressure
    write!(slice, "memory.current", "850")
    assert SystemCgroup.dispatch_headroom(10.0, 0.8) == :healthy
    write!(slice, "cpu.pressure", "some avg10=20.0 avg60=0.0 avg300=0.0 total=10")
    assert SystemCgroup.dispatch_headroom(10.0, 0.8) == :pressure
    write!(slice, "cpu.pressure", "invalid")
    assert SystemCgroup.dispatch_headroom(10.0, 0.8) == :unknown
    write!(slice, "cpu.pressure", "some avg10=2.0 avg60=0.0 avg300=0.0 total=10")
    write!(slice, "memory.current", "925")
    write!(slice, "memory.stat", "invalid")
    assert SystemCgroup.dispatch_headroom(10.0, 0.8) == :unknown
  end

  defp write!(root, name, contents), do: File.write!(Path.join(root, name), contents)

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
