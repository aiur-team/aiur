defmodule Aiur.BuildPriorityTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildGate
  alias Aiur.Config.Schema.Agent

  test "build nice defaults to ten and rejects adjustments outside zero through nineteen" do
    assert %Agent{build_nice: 10} = %Agent{}
    assert {:ok, %{agent: %Agent{build_nice: 10}}} = Aiur.Config.Schema.parse(%{"agent" => %{}})

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
    {output, status} =
      System.cmd("bash", ["-c", "aiur_build_gate_run_or_reuse test echo should-not-run"],
        env: [{"BASH_ENV", BuildGate.hook_path()}, {"AIUR_BUILD_NICE", "20"}, {"AIUR_BUILD_GATE_LEASE_PATH", nil}, {"AIUR_BUILD_GATE_LEASE_TOKEN", nil}],
        stderr_to_stdout: true
      )

    assert status == 125
    assert output =~ "invalid_build_nice"
    refute output =~ "should-not-run"
  end

  @tag skip: not (match?({:unix, :linux}, :os.type()) and not is_nil(System.find_executable("flock")))
  test "admitted commands and nested leases inherit priority once and preserve exit status" do
    root = Path.join(System.tmp_dir!(), "build-priority-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
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
    {baseline, 0} = System.cmd("bash", ["-c", "ps -o ni= -p $$"])
    baseline = baseline |> String.trim() |> String.to_integer()

    for strategy <- ["pid", "linux_lock"], adjustment <- [0, 7, 10] do
      gate = Path.join(root, "#{strategy}-#{adjustment}")
      lock = BuildGate.lock_dir(gate)

      on_exit(fn ->
        File.chmod(lock, 0o755)
        File.rm_rf!(lock)
      end)

      env = BuildGate.shell_env(gate_dir: gate, lock_dir: lock, slots: 1, stagger_seconds: 0, min_free_memory_mb: nil, nice: adjustment)
      assert {"AIUR_BUILD_NICE", Integer.to_string(adjustment)} in env

      {output, status} =
        System.cmd("bash", ["-c", "ps -o ni= -p $$; mix test"],
          env:
            env ++
              [
                {"PATH", root <> ":" <> System.get_env("PATH")},
                {"AIUR_BUILD_GATE_LEASE_STRATEGY", strategy},
                {"AIUR_BUILD_GATE_LEASE_PATH", nil},
                {"AIUR_BUILD_GATE_LEASE_TOKEN", nil},
                {"AIUR_REAL_MIX", executable},
                {"AIUR_BUILD_GATE_BIN", nil}
              ],
          stderr_to_stdout: true
        )

      priorities = Regex.scan(~r/^\s*(-?\d+)\s*$/m, output) |> Enum.map(fn [_, value] -> String.to_integer(value) end)
      assert priorities == [baseline | List.duplicate(min(19, baseline + adjustment), 2)], output
      assert status == 37
    end
  end
end
