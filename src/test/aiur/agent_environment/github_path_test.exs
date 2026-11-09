defmodule Aiur.AgentEnvironment.GitHubPathTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentEnvironment

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "aiur-github-path-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "governed workspace bin is first in local and remote shell PATH" do
    workspace = "/work/aiur/5911"
    bin = Path.join(workspace, ".aiur-runtime/bin")

    assert {~c"PATH", path} = List.keyfind(AgentEnvironment.workspace_env(workspace), ~c"PATH", 0)
    assert List.first(String.split(List.to_string(path), ":")) == bin

    assert AgentEnvironment.workspace_env_export_prefix(workspace) =~
             "PATH='#{bin}'${PATH:+:$PATH}; export PATH"
  end

  test "the trusted login-shell hook restores governed gh after a profile resets PATH", context do
    Application.put_env(:aiur, :build_gate_dir_override, context.tmp_dir)
    on_exit(fn -> Application.delete_env(:aiur, :build_gate_dir_override) end)

    workspace = Path.join(context.tmp_dir, "workspace")
    home = Path.join(context.tmp_dir, "home")
    fake_bin = Path.join(workspace, ".aiur-runtime/bin")
    profile = Path.join(home, ".profile")
    File.mkdir_p!(workspace)
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(home)
    File.write!(Path.join(fake_bin, "gh"), "#!/bin/sh\nprintf governed\n")
    File.chmod!(Path.join(fake_bin, "gh"), 0o755)
    File.write!(profile, "PATH=/usr/bin:/bin; export PATH\n")

    env = AgentEnvironment.workspace_env(workspace)
    {~c"AIUR_AGENT_BIN", bin} = List.keyfind(env, ~c"AIUR_AGENT_BIN", 0)
    {~c"BASH_ENV", hook} = List.keyfind(env, ~c"BASH_ENV", 0)

    assert String.ends_with?(to_string(bin), "/.aiur-runtime/bin")

    assert {output, 0} =
             System.cmd("/bin/bash", ["-lc", "command -v gh; gh"],
               env: [
                 {"HOME", home},
                 {"PATH", "/usr/bin:/bin"},
                 {"AIUR_AGENT_BIN", to_string(bin)},
                 {"BASH_ENV", to_string(hook)}
               ],
               stderr_to_stdout: true
             )

    assert output =~ Path.join(fake_bin, "gh")
    assert output =~ "governed"
  end

  test "agent launch reports when the trusted shell hook cannot be installed", context do
    blocker = Path.join(context.tmp_dir, "not-a-directory")
    File.write!(blocker, "file")
    Application.put_env(:aiur, :build_gate_dir_override, blocker)
    on_exit(fn -> Application.delete_env(:aiur, :build_gate_dir_override) end)

    assert_raise RuntimeError, ~r/agent shell hook unavailable/, fn ->
      Aiur.AgentShellHook.port_env([])
    end
  end
end
