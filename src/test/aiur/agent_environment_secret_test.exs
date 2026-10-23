defmodule Aiur.AgentEnvironmentSecretTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentEnvironment

  test "scrub_shell_command removes the dashboard signing secret before exec" do
    command = AgentEnvironment.scrub_shell_command("env | grep '^AIUR_SECRET_KEY_BASE=' || true")

    {output, 0} =
      System.cmd("bash", ["-lc", command], env: [{"AIUR_SECRET_KEY_BASE", "secret-signing-key"}])

    assert output == ""
  end

  test "workspace environment unsets the dashboard signing secret" do
    env = AgentEnvironment.workspace_env("/work/aiur/5608")

    assert {~c"AIUR_SECRET_KEY_BASE", false} = List.keyfind(env, ~c"AIUR_SECRET_KEY_BASE", 0)
  end
end
