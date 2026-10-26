defmodule Aiur.AgentClientTokenScrubTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentEnvironment

  test "client bearer token is scrubbed from agent environments" do
    previous = System.get_env("AIUR_CLIENT_TOKEN")
    System.put_env("AIUR_CLIENT_TOKEN", "operator-client-token")
    on_exit(fn -> restore_env("AIUR_CLIENT_TOKEN", previous) end)

    assert {~c"AIUR_CLIENT_TOKEN", false} in AgentEnvironment.workspace_env("/work/aiur/5945")

    command = AgentEnvironment.scrub_shell_command("env | grep -E '^AIUR_CLIENT_TOKEN=' | sort")

    {output, 0} = System.cmd("bash", ["-lc", command], env: [{"AIUR_CLIENT_TOKEN", "operator-client-token"}])

    assert output == ""
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
