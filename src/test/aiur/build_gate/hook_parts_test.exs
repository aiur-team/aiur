Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.HookPartsTest do
  use Aiur.TestSupport.BuildGateCase

  @parts ~w(classify lease process run_linux run_pid)

  # Guards future edits: a syntax error in any part breaks every agent shell.
  test "the hook and every part it sources parse as Bash" do
    priv_dir = Path.dirname(BuildGate.hook_path())
    parts = priv_dir |> Path.join("build_gate/*.bash") |> Path.wildcard() |> Enum.sort()

    assert Enum.map(parts, &Path.basename(&1, ".bash")) == @parts

    Enum.each([BuildGate.hook_path() | parts], fn path ->
      assert {"", 0} = System.cmd("bash", ["-n", path], stderr_to_stdout: true)
    end)
  end

  test "a hook with a missing part fails closed without running Mix", context do
    Enum.each(@parts, fn part ->
      hook = copy_hook!(context, part)
      missing = Path.join(Path.dirname(hook), "build_gate/#{part}.bash")
      File.rm!(missing)

      Enum.each(["mix compile", "mise exec -- mix compile", "elixir -S mix compile"], fn command ->
        assert {output, 125} = run_bash(command, Map.put(context, :bash_env, hook))
        assert output =~ "aiur_build_gate gate_error reason=missing_part path=#{missing} status=125"
      end)
    end)

    refute File.exists?(context.log_path)
  end

  test "a relative hook path sources its parts from the hook's own directory", context do
    hook_dir = Path.dirname(copy_hook!(context, "relative"))

    # A bare file name has no directory component; a nested path is relative to
    # a working directory that does not itself hold the parts.
    Enum.each([{hook_dir, "build_gate.bash"}, {Path.dirname(hook_dir), "relative/build_gate.bash"}], fn {cwd, bash_env} ->
      env = Enum.map(build_gate_env(context), &relative_bash_env(&1, bash_env))
      File.rm_rf!(context.log_path)

      assert {output, 0} = System.cmd("bash", ["-c", "mix compile"], cd: cwd, env: env, stderr_to_stdout: true)
      assert output =~ "aiur_build_gate acquired slot=1"
      assert File.read!(context.log_path) == "compile\n"
    end)
  end

  defp relative_bash_env({"BASH_ENV", _path}, bash_env), do: {"BASH_ENV", bash_env}
  defp relative_bash_env(entry, _bash_env), do: entry

  defp copy_hook!(context, name) do
    priv_dir = Path.dirname(BuildGate.hook_path())
    copy_dir = Path.join([context.gate_dir, "hook-copies", name])
    File.mkdir_p!(copy_dir)

    Enum.each(["build_gate.bash", "browser_build_gate.bash", "build_priority.bash", "build_gate_holder.py"], fn file ->
      File.cp!(Path.join(priv_dir, file), Path.join(copy_dir, file))
    end)

    File.cp_r!(Path.join(priv_dir, "build_gate"), Path.join(copy_dir, "build_gate"))
    File.cp_r!(Path.join(priv_dir, "build_gate_holder_lib"), Path.join(copy_dir, "build_gate_holder_lib"))
    Path.join(copy_dir, "build_gate.bash")
  end
end
