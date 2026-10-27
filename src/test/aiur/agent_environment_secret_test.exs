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

  test "workspace environment unsets the shared coordination database credential" do
    env = AgentEnvironment.workspace_env("/work/aiur/5947")

    assert {~c"AIUR_LEASE_DATABASE_URL", false} =
             List.keyfind(env, ~c"AIUR_LEASE_DATABASE_URL", 0)
  end

  test "workspace environment scrubs the operator Claude token before backend selection" do
    env = AgentEnvironment.workspace_env("/work/aiur/5943")
    assert {~c"CLAUDE_CODE_OAUTH_TOKEN", false} = List.keyfind(env, ~c"CLAUDE_CODE_OAUTH_TOKEN", 0)
    provider_names = AgentEnvironment.provider_credential_env_names()
    assert "OPENAI_API_KEY" in provider_names
    assert "ANTHROPIC_API_KEY" in provider_names

    command = AgentEnvironment.scrub_shell_command("env | grep '^CLAUDE_CODE_OAUTH_TOKEN=' || true")
    {output, 0} = System.cmd("bash", ["-lc", command], env: [{"CLAUDE_CODE_OAUTH_TOKEN", "subscription-token"}])
    assert output == ""
  end
end
