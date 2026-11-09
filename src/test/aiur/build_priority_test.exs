defmodule Aiur.BuildPriorityTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildGate
  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.Agent

  test "build nice defaults to ten and rejects adjustments outside zero through nineteen" do
    assert %Agent{build_nice: 10} = %Agent{}
    assert {:ok, %{agent: %Agent{build_nice: 10}}} = Schema.parse(%{"agent" => %{}})

    for value <- [0, 7, 19] do
      changeset = Agent.changeset(%Agent{}, %{"build_nice" => value})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :build_nice) == value
    end

    for value <- [-1, 20, nil] do
      changeset = Agent.changeset(%Agent{}, %{"build_nice" => value})
      assert Keyword.has_key?(changeset.errors, :build_nice)
    end
  end

  test "invalid shell priority fails closed before executing a command" do
    gate = Path.join(System.tmp_dir!(), "build-priority-invalid-#{System.unique_integer([:positive])}")
    lock = BuildGate.lock_dir(gate)
    env = BuildGate.shell_env(gate_dir: gate, lock_dir: lock, slots: 1, stagger_seconds: 0, min_free_memory_mb: nil, nice: 0)

    on_exit(fn ->
      File.chmod(lock, 0o755)
      Aiur.TestCleanup.rm_rf!(lock)
      Aiur.TestCleanup.rm_rf!(gate)
      Aiur.TestCleanup.rm_rf!(gate <> ".hooks")
    end)

    {output, status} =
      System.cmd("bash", ["-c", "aiur_build_gate_run_or_reuse test echo should-not-run"],
        env: env ++ [{"AIUR_BUILD_NICE", "20"}, {"AIUR_MIN_FREE_MEMORY_MB", nil}, {"AIUR_BUILD_GATE_LEASE_PATH", nil}, {"AIUR_BUILD_GATE_LEASE_TOKEN", nil}],
        stderr_to_stdout: true
      )

    assert status == 125
    assert output =~ "invalid_build_nice"
    refute output =~ "should-not-run"
  end

  # #7291 diagnostic: names the sender of a TERM/HUP/INT sent to the command's process group.
  @signal_witness """
  import signal, sys
  sigs = {signal.SIGTERM, signal.SIGHUP, signal.SIGINT}
  signal.pthread_sigmask(signal.SIG_BLOCK, sigs)
  info = signal.sigtimedwait(sigs, 120)
  def read(path):
      try:
          return open(path, "rb").read().replace(b"\\0", b" ").decode(errors="replace").strip()
      except OSError as error:
          return f"<{error.strerror}>"
  if info:
      stat = read(f"/proc/{info.si_pid}/stat")
      ppid = stat.rsplit(")", 1)[1].split()[1] if ")" in stat else "?"
      with open(sys.argv[1], "a") as out:
          out.write(f"signal={info.si_signo} sender={info.si_pid} cmd={read(f'/proc/{info.si_pid}/cmdline')!r} "
                    f"ppid={ppid} parent_cmd={read(f'/proc/{ppid}/cmdline')!r}\\n")
  """

  @tag skip: not (match?({:unix, :linux}, :os.type()) and not is_nil(System.find_executable("flock")))
  test "admitted commands and nested leases inherit priority once and preserve exit status" do
    root = Path.join(System.tmp_dir!(), "build-priority-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    executable = Path.join(root, "mix")

    File.write!(executable, """
    #!/bin/bash
    ps -o ni= -p "$$"
    if [[ $1 == test ]]; then
      bash -c 'mix compile'
    else
      exit 37
    fi
    """)

    File.chmod!(executable, 0o755)
    witness = Path.join(root, "signal_witness.py")
    File.write!(witness, @signal_witness)
    {baseline, 0} = System.cmd("bash", ["-c", "ps -o ni= -p $$"])
    baseline = baseline |> String.trim() |> String.to_integer()

    for strategy <- ["pid", "linux_lock"], adjustment <- [0, 7, 10] do
      gate = Path.join(root, "#{strategy}-#{adjustment}")
      lock = BuildGate.lock_dir(gate)

      {signals, witness_pid} = {gate <> ".signals", gate <> ".witness-pid"}

      on_exit(fn ->
        with {:ok, pid} <- File.read(witness_pid), {:ok, cmdline} <- File.read("/proc/#{String.trim(pid)}/cmdline"), true <- cmdline =~ "signal_witness" do
          System.cmd("kill", ["-KILL", String.trim(pid)], stderr_to_stdout: true)
        end

        File.chmod(lock, 0o755)
        Aiur.TestCleanup.rm_rf!(lock)
      end)

      env = BuildGate.shell_env(gate_dir: gate, lock_dir: lock, slots: 1, stagger_seconds: 0, min_free_memory_mb: nil, nice: adjustment)
      assert {"AIUR_BUILD_NICE", Integer.to_string(adjustment)} in env

      {output, status} =
        System.cmd(
          "bash",
          ["-c", "python3 #{witness} #{signals} </dev/null >/dev/null 2>&1 & echo $! >#{witness_pid}; ps -o ni= -p $$; mix test; rc=$?; kill -KILL $!; exit $rc"],
          env:
            env ++
              [
                {"PATH", root <> ":" <> System.get_env("PATH")},
                {"AIUR_BUILD_GATE_LEASE_STRATEGY", strategy},
                {"AIUR_BUILD_GATE_LEASE_PATH", nil},
                {"AIUR_BUILD_GATE_LEASE_TOKEN", nil},
                {"AIUR_MIN_FREE_MEMORY_MB", nil},
                {"AIUR_REAL_MIX", executable},
                {"AIUR_BUILD_GATE_BIN", nil}
              ],
          stderr_to_stdout: true
        )

      priorities = Regex.scan(~r/^\s*(-?\d+)\s*$/m, output) |> Enum.map(fn [_, value] -> String.to_integer(value) end)
      assert priorities == [baseline | List.duplicate(min(19, baseline + adjustment), 2)], output

      assert status == 37,
             "strategy=#{strategy} adjustment=#{adjustment} status=#{status}\noutput (gate stderr included):\n#{output}\n" <>
               "signal witness: #{witness_report(signals)}"
    end
  end

  defp witness_report(signals) do
    case File.read(signals) do
      {:ok, seen} -> seen
      {:error, _} -> "no TERM/HUP/INT reached the command's process group"
    end
  end
end
