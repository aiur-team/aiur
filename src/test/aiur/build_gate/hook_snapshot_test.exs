Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.HookSnapshotTest do
  use Aiur.TestSupport.BuildGateCase

  alias Aiur.BuildGate.HookSnapshot

  @moduletag @linux_only

  # An agent launched before a release rebuild keeps its BASH_ENV (#4489).
  test "an existing agent's guarded build still admits after its release tree disappears", context do
    release_priv = copy_release_priv!(context)
    {:ok, hook} = HookSnapshot.ensure(release_priv, context.gate_dir <> ".hooks")

    refute String.starts_with?(hook, release_priv)
    Aiur.TestCleanup.rm_rf!(Path.dirname(release_priv))

    agent = context |> with_command_wrappers!() |> Map.put(:bash_env, hook)

    for command <- ["mix compile", "mise exec -- mix compile"] do
      File.rm(context.log_path)
      assert {output, 0} = System.cmd("sh", ["-c", command], env: build_gate_env(agent), stderr_to_stdout: true)
      assert output =~ "aiur_build_gate acquired slot=1"
      assert File.read!(context.log_path) == "compile\n"
    end
  end

  test "the same hook reuses one snapshot and a changed hook gets a new one", context do
    release_priv = copy_release_priv!(context)
    root = context.gate_dir <> ".hooks"

    {:ok, first} = HookSnapshot.ensure(release_priv, root)
    assert {:ok, ^first} = HookSnapshot.ensure(release_priv, root)

    File.write!(Path.join(release_priv, "build_gate/classify.bash"), "\n# changed\n", [:append])
    {:ok, second} = HookSnapshot.ensure(release_priv, root)

    assert second != first
    assert File.regular?(first)
    assert File.regular?(Path.join(Path.dirname(second), "build_gate_holder_lib/files.py"))
    assert root |> File.ls!() |> Enum.sort() == Enum.sort(for hook <- [first, second], do: hook |> Path.dirname() |> Path.basename())
  end

  test "shell_env hands agents the snapshot rather than the release hook", context do
    env = BuildGate.shell_env(gate_dir: context.gate_dir, lock_dir: context.lock_dir, slots: 1, stagger_seconds: 0, min_free_memory_mb: nil, nice: 0)

    assert {"BASH_ENV", hook} = List.keyfind(env, "BASH_ENV", 0)
    assert Path.dirname(Path.dirname(hook)) == context.gate_dir <> ".hooks"
    assert File.read!(hook) == File.read!(BuildGate.hook_path())
  end

  defp copy_release_priv!(context) do
    release_priv = Path.join([context.gate_dir, "release", "priv"])
    priv = Path.dirname(BuildGate.hook_path())
    File.mkdir_p!(release_priv)

    for entry <- ~w(build_gate.bash browser_build_gate.bash build_priority.bash build_gate_holder.py build_gate build_gate_holder_lib) do
      File.cp_r!(Path.join(priv, entry), Path.join(release_priv, entry))
    end

    release_priv
  end
end
