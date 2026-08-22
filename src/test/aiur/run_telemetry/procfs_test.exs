defmodule Aiur.RunTelemetry.ProcfsTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.Procfs

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-procfs-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "parse_stat/1 handles spaces and parentheses in comm" do
    stat = stat_line(42, "codex worker (test)", 7, 10, 5, 99)

    assert {:ok, %{pid: 42, ppid: 7, cpu_ticks: 15, start_time_ticks: 99}} =
             Procfs.parse_stat(stat)
  end

  test "parses RSS and physical I/O counters without command text" do
    status = "Name:\tcodex\nVmRSS:\t2048 kB\nThreads:\t8\n"
    io = "rchar: 99\nwchar: 88\nread_bytes: 4096\nwrite_bytes: 8192\n"

    assert {:ok, 2_097_152} = Procfs.parse_rss_bytes(status)
    assert {:ok, %{read_bytes: 4096, write_bytes: 8192}} = Procfs.parse_io(io)
  end

  test "process_table/1 reads numeric entries once and reports malformed processes", %{root: root} do
    write_process(root, 1, stat_line(1, "beam.smp", 0, 5, 6, 10))
    write_process(root, 2, "malformed")
    File.mkdir_p!(Path.join(root, "self"))

    assert {:ok, table, warnings} = Procfs.process_table(root: root)
    assert table == %{1 => %{pid: 1, ppid: 0, cpu_ticks: 11, start_time_ticks: 10}}
    assert Enum.any?(warnings, &(&1.pid == 2 and &1.field == :stat))
  end

  test "measure_many/3 keeps partial processes when files disappear", %{root: root} do
    write_process(root, 1, stat_line(1, "beam.smp", 0, 5, 6, 10))
    write_details(root, 1, rss_kb: 100, read_bytes: 20, write_bytes: 30, fds: 3)
    write_process(root, 2, stat_line(2, "short-lived", 1, 1, 2, 20))

    {:ok, table, []} = Procfs.process_table(root: root)
    File.rm_rf!(Path.join(root, "2"))

    assert {:ok, measured, warnings} =
             Procfs.measure_many(table, MapSet.new([1, 2]), root: root)

    assert measured[1].rss_bytes == 102_400
    assert measured[1].fd_count == 3
    assert measured[1].read_bytes == 20
    assert measured[1].write_bytes == 30
    assert measured[2].rss_bytes == nil
    assert measured[2].fd_count == nil
    assert Enum.any?(warnings, &(&1.pid == 2))
  end

  test "missing procfs is explicitly unavailable", %{root: root} do
    missing = Path.join(root, "missing")
    assert {:error, {:procfs_unavailable, :enoent}} = Procfs.process_table(root: missing)
  end

  defp stat_line(pid, comm, ppid, utime, stime, start_time) do
    fields = [
      "S",
      Integer.to_string(ppid),
      "0",
      "0",
      "0",
      "0",
      "0",
      "0",
      "0",
      "0",
      "0",
      Integer.to_string(utime),
      Integer.to_string(stime),
      "0",
      "0",
      "0",
      "0",
      "1",
      "0",
      Integer.to_string(start_time)
    ]

    "#{pid} (#{comm}) #{Enum.join(fields, " ")}\n"
  end

  defp write_process(root, pid, stat) do
    dir = Path.join(root, Integer.to_string(pid))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "stat"), stat)
  end

  defp write_details(root, pid, opts) do
    dir = Path.join(root, Integer.to_string(pid))
    File.write!(Path.join(dir, "status"), "VmRSS:\t#{Keyword.fetch!(opts, :rss_kb)} kB\n")

    File.write!(
      Path.join(dir, "io"),
      "read_bytes: #{Keyword.fetch!(opts, :read_bytes)}\nwrite_bytes: #{Keyword.fetch!(opts, :write_bytes)}\n"
    )

    fd_dir = Path.join(dir, "fd")
    File.mkdir_p!(fd_dir)

    for fd <- 0..(Keyword.fetch!(opts, :fds) - 1) do
      File.write!(Path.join(fd_dir, Integer.to_string(fd)), "")
    end
  end
end
