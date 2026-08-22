defmodule Aiur.AgentProcessLogTest do
  use Aiur.TestSupport

  alias Aiur.AgentProcessLog

  @now ~U[2026-08-09 21:00:00Z]

  defp tmp_path do
    path = Path.join(System.tmp_dir!(), "aiur-agent-process-log-#{System.unique_integer([:positive])}.tsv")
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp roots_fun, do: fn -> [{100, "2255"}] end

  defp processes_fun do
    fn ->
      %{
        100 => %{pid: 100, ppid: 0, comm: "codex", cmdline: "codex exec"},
        101 => %{pid: 101, ppid: 100, comm: "git-remote-https", cmdline: "git-remote-https origin"},
        102 => %{pid: 102, ppid: 100, comm: "beam.smp", cmdline: "beam.smp -S 4:4"},
        103 => %{pid: 103, ppid: 101, comm: "mix", cmdline: "mix test"}
      }
    end
  end

  defp cwd_fun do
    fn
      103 -> "/ws/2255/src"
      _other -> "/ws/2255"
    end
  end

  test "records subprocess spawns attributed to the ticket that owns the root" do
    path = tmp_path()

    AgentProcessLog.sweep_once(
      roots_fun: roots_fun(),
      processes_fun: processes_fun(),
      cwd_fun: cwd_fun(),
      path: path,
      clock: fn -> @now end
    )

    rows = File.read!(path) |> String.split("\n", trim: true)
    assert length(rows) == 4

    ts = Integer.to_string(DateTime.to_unix(@now))

    assert Enum.any?(rows, fn row ->
             match?([^ts, "start", "100", "2255", "100", "0", "codex", "codex exec", "/ws/2255", ""], String.split(row, "\t"))
           end)

    assert Enum.any?(rows, fn row ->
             match?([^ts, "start", "100", "2255", "101", "100", "git-remote-https", "git-remote-https origin", "/ws/2255", ""], String.split(row, "\t"))
           end)

    assert Enum.any?(rows, fn row ->
             match?([^ts, "start", "100", "2255", "102", "100", "beam.smp", "beam.smp -S 4:4", "/ws/2255", ""], String.split(row, "\t"))
           end)

    assert Enum.any?(rows, fn row ->
             match?([^ts, "start", "100", "2255", "103", "101", "mix", "mix test", "/ws/2255/src", ""], String.split(row, "\t"))
           end)
  end

  test "appends an exit row with duration when a subprocess disappears" do
    path = tmp_path()
    {:ok, clock} = Agent.start_link(fn -> @now end)
    clock_fun = fn -> Agent.get(clock, & &1) end

    processes =
      AgentProcessLog.sweep_once(
        roots_fun: roots_fun(),
        processes_fun: processes_fun(),
        cwd_fun: cwd_fun(),
        path: path,
        clock: clock_fun
      )

    # A sweep where the whole tree persists writes no new rows — a process's
    # lifetime is measured from its first observation, not the last sweep.
    Agent.update(clock, fn _ -> DateTime.add(@now, 10, :second) end)

    processes =
      AgentProcessLog.sweep_once(
        roots_fun: roots_fun(),
        processes_fun: processes_fun(),
        cwd_fun: cwd_fun(),
        processes: processes,
        path: path,
        clock: clock_fun
      )

    assert length(File.read!(path) |> String.split("\n", trim: true)) == 4

    # The beam.smp VM (102) exits ten seconds later; its duration counts from
    # its first observation at T0, not from the previous sweep at T0+10.
    Agent.update(clock, fn _ -> DateTime.add(@now, 20, :second) end)

    AgentProcessLog.sweep_once(
      roots_fun: roots_fun(),
      processes_fun: fn ->
        %{
          100 => %{pid: 100, ppid: 0, comm: "codex", cmdline: "codex exec"},
          101 => %{pid: 101, ppid: 100, comm: "git-remote-https", cmdline: "git-remote-https origin"},
          103 => %{pid: 103, ppid: 101, comm: "mix", cmdline: "mix test"}
        }
      end,
      cwd_fun: cwd_fun(),
      processes: processes,
      path: path,
      clock: clock_fun
    )

    rows = File.read!(path) |> String.split("\n", trim: true)
    assert length(rows) == 5

    ts = Integer.to_string(DateTime.to_unix(DateTime.add(@now, 20, :second)))
    assert [^ts, "exit", "100", "2255", "102", "100", "beam.smp", "", "", "20"] = rows |> List.last() |> String.split("\t")
  end

  test "redacts credential shapes from recorded command lines" do
    path = tmp_path()

    AgentProcessLog.sweep_once(
      roots_fun: roots_fun(),
      processes_fun: fn ->
        %{
          100 => %{pid: 100, ppid: 0, comm: "codex", cmdline: "codex exec"},
          201 => %{pid: 201, ppid: 100, comm: "curl", cmdline: "curl -H 'Authorization: Bearer ghp_abcdef1234567890' https://api.github.com/user"}
        }
      end,
      cwd_fun: fn _ -> "/ws" end,
      path: path,
      clock: fn -> @now end
    )

    content = File.read!(path)
    refute content =~ "ghp_abcdef1234567890"
    assert content =~ "Authorization: Bearer <redacted>"
  end

  test "is a no-op without a log path" do
    assert %{} =
             AgentProcessLog.sweep_once(
               roots_fun: roots_fun(),
               processes_fun: processes_fun(),
               cwd_fun: cwd_fun(),
               path: nil,
               clock: fn -> @now end
             )
  end
end
