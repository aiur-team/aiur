Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.HookSnapshotTest do
  use Aiur.TestSupport.BuildGateCase

  import Bitwise

  alias Aiur.BuildGate.HookSnapshot

  @moduletag @linux_only

  # An agent launched before a release rebuild keeps its BASH_ENV (#4489).
  test "an agent's guarded builds still admit after its release tree disappears mid-build", context do
    release_priv = copy_release_priv!(context)
    release_descendant_on_exit(context)
    # The agent keeps the BASH_ENV that shell_env gave it at launch from this release.
    Application.put_env(:aiur, :build_gate_priv_dir_override, release_priv)
    on_exit(fn -> Application.delete_env(:aiur, :build_gate_priv_dir_override) end)
    env = BuildGate.shell_env(gate_dir: context.gate_dir, lock_dir: context.lock_dir, slots: 1, stagger_seconds: 0, min_free_memory_mb: nil, nice: 0)
    Application.delete_env(:aiur, :build_gate_priv_dir_override)
    assert {"BASH_ENV", hook} = List.keyfind(env, "BASH_ENV", 0)
    agent = context |> with_command_wrappers!() |> Map.merge(%{bash_env: hook, started_path: ""})

    # In flight: the holder keeps the slot while a Mix descendant still runs.
    assert {output, 0} = run_bash("mix test", Map.put(agent, :descendant_release_barrier, true))
    assert output =~ "aiur_build_gate lease_retained slot=1 status=0"
    wait_for_file!(context.descendant_path)

    Aiur.TestCleanup.rm_rf!(Path.dirname(release_priv))
    release_descendant!(context)
    wait_for_status!(context.gate_dir, 1, &(&1.active == 0))

    for command <- ["mix compile", "mise exec -- mix compile"] do
      assert {output, 0} = run_bash(command, agent)
      assert output =~ "aiur_build_gate acquired slot=1"
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

  test "a damaged snapshot is republished rather than reused", context do
    release_priv = copy_release_priv!(context)
    root = context.gate_dir <> ".hooks"
    {:ok, hook} = HookSnapshot.ensure(release_priv, root)
    snapshot = Path.dirname(hook)

    assert (File.stat!(hook).mode &&& 0o777) == 0o444
    assert (File.stat!(snapshot).mode &&& 0o777) == 0o555

    # An agent that unseals the snapshot can still damage it.
    System.cmd("chmod", ["-R", "u+w", snapshot])
    Aiur.TestCleanup.rm_rf!(Path.join(snapshot, "build_gate_holder_lib"))
    File.write!(Path.join(snapshot, "build_gate/classify.bash"), "return 0\n")
    File.chmod!(snapshot, 0o555)

    assert {:ok, ^hook} = HookSnapshot.ensure(release_priv, root)
    assert File.read!(Path.join(snapshot, "build_gate/classify.bash")) == File.read!(Path.join(release_priv, "build_gate/classify.bash"))
    assert File.regular?(Path.join(snapshot, "build_gate_holder_lib/files.py"))
  end

  test "a stage left by a dead publisher is removed once stale", context do
    root = context.gate_dir <> ".hooks"
    [stale, fresh] = for name <- ~w(.stage-dead-1 .stage-live-2), do: Path.join(root, name)
    Enum.each([stale, fresh], &File.mkdir_p!/1)
    File.touch!(stale, System.os_time(:second) - 7200)

    {:ok, _hook} = HookSnapshot.ensure(copy_release_priv!(context), root)

    refute File.exists?(stale)
    assert File.dir?(fresh)
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
