defmodule Aiur.AgentEnvironment.RemoteInstanceTokenScrubTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentEnvironment

  test "no remote instance token survives into an agent environment" do
    credentials = [{"AIUR_TOKEN_NUC", "nuc-token"}, {"AIUR_TOKEN_RAILWAY_1", "railway-token"}]
    previous = Enum.map(credentials, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(credentials, fn {name, value} -> System.put_env(name, value) end)
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)

    env = AgentEnvironment.workspace_env("/work/aiur/5968")

    Enum.each(credentials, fn {name, _value} ->
      assert {String.to_charlist(name), false} in env, "#{name} is not unset for the agent process"
    end)

    command = AgentEnvironment.scrub_shell_command("! env | grep '^AIUR_TOKEN_'")
    assert {"", 0} = System.cmd("bash", ["-lc", command], env: credentials)

    prefix = AgentEnvironment.workspace_env_export_prefix("/work/aiur/5968", base_branch: "main")

    assert {"0\n", 0} =
             System.cmd("bash", ["-lc", "#{prefix}; env | grep -c '^AIUR_TOKEN_' || true"], env: credentials ++ [{"HOME", "/remote-home"}])
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
