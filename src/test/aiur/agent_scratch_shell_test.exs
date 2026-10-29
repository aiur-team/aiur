defmodule Aiur.AgentScratchShellTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentEnvironment

  setup do
    workspace = Aiur.TestSupport.tmp_root!("aiur-env-scratch")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  # Some CI runners do not install zsh. Keep this integration coverage enabled
  # wherever the shell exists; TMPPREFIX also has shell-independent env tests.
  @tag skip: is_nil(System.find_executable("zsh"))
  test "local agent zsh heredocs use private scratch when inherited temp is unusable", %{
    workspace: workspace
  } do
    blocked = Path.join(workspace, "blocked")
    File.write!(blocked, "regular file")
    scratch = AgentEnvironment.workspace_env(workspace)

    temp_env =
      scratch
      |> Enum.filter(fn {name, _} -> name in [~c"TMPDIR", ~c"TMP", ~c"TEMP", ~c"TMPPREFIX"] end)
      |> Map.new(fn {name, value} -> {to_string(name), to_string(value)} end)

    {output, 0} =
      System.cmd("zsh", ["-c", "wc -c <<EOF\nworkpad\nEOF"],
        env: [
          {"TMPDIR", temp_env["TMPDIR"]},
          {"TMPPREFIX", Map.get(temp_env, "TMPPREFIX", Path.join(blocked, "zsh-"))}
        ],
        stderr_to_stdout: true
      )

    assert output == "8\n"
  end

  @tag skip: is_nil(System.find_executable("zsh"))
  test "SSH agent zsh heredocs use private scratch when inherited temp is unusable", %{
    workspace: workspace
  } do
    blocked = Path.join(workspace, "blocked")
    File.write!(blocked, "regular file")
    prefix = AgentEnvironment.workspace_env_export_prefix(workspace, base_branch: "develop")

    {output, 0} =
      System.cmd("bash", ["-c", "#{prefix} && zsh -c 'wc -c <<EOF\nworkpad\nEOF'"],
        env: [{"TMPPREFIX", Path.join(blocked, "zsh-")}],
        stderr_to_stdout: true
      )

    assert output == "8\n"
  end
end
