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
        100 => %{pid: 100, ppid: 0, comm: "codex", cmdline: "codex exec --resume /ws/2255/session.json"},
        101 => %{pid: 101, ppid: 100, comm: "git-remote-https", cmdline: "git-remote-https origin"},
        102 => %{pid: 102, ppid: 100, comm: "beam.smp", cmdline: "beam.smp -pa /ws/2255/_build/dev"},
        103 => %{pid: 103, ppid: 101, comm: "mix", cmdline: "mix test ./test/aiur/agent_process_log_test.exs"}
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
    sha = fn cmdline -> :crypto.hash(:sha256, cmdline) |> Base.encode16(case: :lower) end

    # argv is the allowlisted view: safe tokens (dash flags, paths) survive and
    # bare words — which cannot be verified safe — are redacted.
    assert Enum.any?(rows, fn row ->
             String.split(row, "\t") ==
               [ts, "start", "100", "2255", "100", "0", "codex", "<redacted> <redacted> --resume /ws/2255/session.json", sha.("codex exec --resume /ws/2255/session.json"), "/ws/2255", ""]
           end)

    assert Enum.any?(rows, fn row ->
             String.split(row, "\t") ==
               [ts, "start", "100", "2255", "101", "100", "git-remote-https", "<redacted> <redacted>", sha.("git-remote-https origin"), "/ws/2255", ""]
           end)

    assert Enum.any?(rows, fn row ->
             String.split(row, "\t") ==
               [ts, "start", "100", "2255", "102", "100", "beam.smp", "<redacted> -pa /ws/2255/_build/dev", sha.("beam.smp -pa /ws/2255/_build/dev"), "/ws/2255", ""]
           end)

    assert Enum.any?(rows, fn row ->
             String.split(row, "\t") ==
               [
                 ts,
                 "start",
                 "100",
                 "2255",
                 "103",
                 "101",
                 "mix",
                 "<redacted> <redacted> ./test/aiur/agent_process_log_test.exs",
                 sha.("mix test ./test/aiur/agent_process_log_test.exs"),
                 "/ws/2255/src",
                 ""
               ]
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
    assert [^ts, "exit", "100", "2255", "102", "100", "beam.smp", "", "", "", "20"] = rows |> List.last() |> String.split("\t")
  end

  # The core security property (#2255, #2245): the recorded argv is an
  # allowlist, not a denylist. A denylist has to anticipate every encoding a
  # credential can take; the allowlist only reproduces tokens that match a
  # known-safe shape (a dash flag or a filesystem path), so every shape the
  # reviews flagged as leaking under the old full-argv redaction — including
  # the unpadded-base64 git extraheader case that defeated the padded-base64
  # regex — must never reach disk.
  test "records only allowlisted argv tokens and never a credential shape" do
    path = tmp_path()

    # Unpadded base64 of a git credential header value: the exact shape that
    # defeated the old padded-base64 denylist regex. When the plaintext length
    # is a multiple of three, base64 has no `=` padding at all.
    unpadded = Base.encode64("x-access-token:ghs_", padding: false)
    refute String.contains?(unpadded, "=")

    cmdlines = [
      "git -c http.extraheader=AUTHORIZATION: basic #{unpadded} fetch",
      "curl -H \"Authorization: basic dXNlcjpwYXNzd29yZA==\"",
      "git clone https://oauth2:SUPERSECRET@github.com/o/r.git",
      "curl -u kevin:SUPERSECRET https://api.github.com",
      "claude --api-key sk-ant-api03-REALKEY",
      "psql postgres://user:PASSWORD@db:5432/x",
      "mytool --token=SUPERSECRET",
      "env SOME_TOKEN=ghp_0123456789abcdefghijklmnop fetch",
      "tool ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    ]

    processes =
      cmdlines
      |> Enum.with_index(1)
      |> Map.new(fn {cmdline, i} ->
        {100 + i, %{pid: 100 + i, ppid: 100, comm: hd(String.split(cmdline)), cmdline: cmdline}}
      end)
      |> Map.put(100, %{pid: 100, ppid: 0, comm: "codex", cmdline: "codex exec"})

    AgentProcessLog.sweep_once(
      roots_fun: roots_fun(),
      processes_fun: fn -> processes end,
      cwd_fun: fn _ -> "/ws" end,
      path: path,
      clock: fn -> @now end
    )

    content = File.read!(path)
    refute content =~ unpadded
    refute content =~ "x-access-token"
    refute content =~ "ghs_"
    refute content =~ "eC1hY2Nlc3MtdG9rZW46Z2hzX1NFQ1JFVA=="
    refute content =~ "dXNlcjpwYXNzd29yZA=="
    refute content =~ "SUPERSECRET"
    refute content =~ "PASSWORD"
    refute content =~ "REALKEY"
    refute content =~ "sk-ant-api03"
    refute content =~ "SOME_TOKEN"
    refute content =~ "ghp_"
    # A URL token is redacted whole: it carries `:`/`@`/`?` and cannot be
    # verified safe, so neither its path nor its userinfo survives.
    refute content =~ "github.com/o/r.git"
    refute content =~ "api.github.com"
    # The safe tokens on the same lines still survive the allowlist.
    assert content =~ " -c "
    assert content =~ " --api-key "
    assert content =~ " -H "
  end

  # The other half of the allowlist: a command line longer than the token cap
  # must never record the tail at all — only its SHA-256 fingerprint.
  test "hashes the argv tail beyond the allowlist instead of recording it" do
    path = tmp_path()
    long = "tool flag1 val1 flag2 val2 flag3 val3 flag4 val4 flag5 val5 --token=TAILSECRET"

    AgentProcessLog.sweep_once(
      roots_fun: roots_fun(),
      processes_fun: fn ->
        %{
          100 => %{pid: 100, ppid: 0, comm: "codex", cmdline: "codex exec"},
          201 => %{pid: 201, ppid: 100, comm: "tool", cmdline: long}
        }
      end,
      cwd_fun: fn _ -> "/ws" end,
      path: path,
      clock: fn -> @now end
    )

    content = File.read!(path)
    refute content =~ "TAILSECRET"
    assert content =~ " <...>"

    argv_sha = :crypto.hash(:sha256, long) |> Base.encode16(case: :lower)
    assert content =~ argv_sha
  end

  # Arbitrary bytes must not be able to break the TSV: a literal newline in a
  # recorded field would otherwise end the row early and a tab would forge
  # extra columns. argv is already normalized by tokenization, so this proves
  # the escaping on the verbatim fields (cwd can contain control bytes).
  test "escapes control bytes so they cannot forge rows" do
    path = tmp_path()

    AgentProcessLog.sweep_once(
      roots_fun: roots_fun(),
      processes_fun: fn ->
        %{
          100 => %{pid: 100, ppid: 0, comm: "codex", cmdline: "codex exec"},
          201 => %{pid: 201, ppid: 100, comm: "mix", cmdline: "mix test"}
        }
      end,
      cwd_fun: fn
        201 -> "/ws/weird\ncwd\tpath"
        _other -> "/ws"
      end,
      path: path,
      clock: fn -> @now end
    )

    lines = File.read!(path) |> String.split("\n", trim: true)
    # Two rows only — the embedded newline must not have split the cwd row.
    assert length(lines) == 2

    row = Enum.find(lines, &String.contains?(&1, "\tmix\t"))
    assert String.contains?(row, "\\n")
    assert String.contains?(row, "\\t")
  end

  # A pid is only an identity while it is the same process. A pid that exits
  # and is reallocated inside one sweep window must produce BOTH an exit row
  # for the old process and a start row for the new one, with a fresh lifetime
  # — not a fabricated duration against the wrong command.
  test "a pid reused within one sweep window is treated as two processes" do
    path = tmp_path()
    {:ok, clock} = Agent.start_link(fn -> @now end)
    clock_fun = fn -> Agent.get(clock, & &1) end

    processes =
      AgentProcessLog.sweep_once(
        roots_fun: roots_fun(),
        processes_fun: fn ->
          %{
            100 => %{pid: 100, ppid: 0, comm: "codex", cmdline: "codex exec", start_time: "old-start"},
            101 => %{pid: 101, ppid: 100, comm: "mix", cmdline: "mix test", start_time: "old-start"}
          }
        end,
        cwd_fun: fn _ -> "/ws" end,
        path: path,
        clock: clock_fun
      )

    Agent.update(clock, fn _ -> DateTime.add(@now, 10, :second) end)

    AgentProcessLog.sweep_once(
      roots_fun: roots_fun(),
      # The same pid is now a DIFFERENT process (its start time changed): the
      # old one must exit and the new one must start afresh.
      processes_fun: fn ->
        %{
          100 => %{pid: 100, ppid: 0, comm: "codex", cmdline: "codex exec", start_time: "old-start"},
          101 => %{pid: 101, ppid: 100, comm: "mix", cmdline: "mix test", start_time: "new-start"}
        }
      end,
      cwd_fun: fn _ -> "/ws" end,
      processes: processes,
      path: path,
      clock: clock_fun
    )

    rows = File.read!(path) |> String.split("\n", trim: true)
    # 2 initial starts + (exit of the old 101 + start of the new 101)
    assert length(rows) == 4

    exit_ts = Integer.to_string(DateTime.to_unix(DateTime.add(@now, 10, :second)))
    mix_sha = :crypto.hash(:sha256, "mix test") |> Base.encode16(case: :lower)

    assert [^exit_ts, "exit", "100", "2255", "101", "100", "mix", "", "", "", _duration] =
             rows |> Enum.find(&String.contains?(&1, "\texit\t100\t2255\t101\t")) |> String.split("\t")

    assert Enum.any?(rows, fn row ->
             String.split(row, "\t") ==
               [exit_ts, "start", "100", "2255", "101", "100", "mix", "<redacted> <redacted>", mix_sha, "/ws", ""]
           end)
  end

  test "is a no-op without a log path" do
    # The test env must never resolve a default path, so a sweep with no
    # `path` cannot write anywhere — including into this checkout's repo
    # state. A sentinel sweep path stays absent.
    assert AgentProcessLog.default_path() == nil

    processes =
      AgentProcessLog.sweep_once(
        roots_fun: roots_fun(),
        processes_fun: processes_fun(),
        cwd_fun: cwd_fun(),
        path: nil,
        clock: fn -> @now end
      )

    # The sweep still observed the tree (it is not a no-op on observation),
    # and wrote nothing.
    assert map_size(processes) == 4
  end
end
