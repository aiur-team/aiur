defmodule Aiur.AgentEnvironmentTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentEnvironment

  test "identifies inherited Erlang distribution environment names" do
    assert AgentEnvironment.erlang_distribution_env_name?("ERL_AFLAGS")
    assert AgentEnvironment.erlang_distribution_env_name?("RELEASE_NODE")
    assert AgentEnvironment.erlang_distribution_env_name?("RELEASE_COOKIE")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_NODE_NAME")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_AGENT_NODE_NAME")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_COOKIE")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_ERLANG_COOKIE")

    refute AgentEnvironment.erlang_distribution_env_name?("OTHER_COOKIE")
    refute AgentEnvironment.erlang_distribution_env_name?("PATH")
  end

  test "scrub_shell_command clears Erlang distribution environment before exec" do
    command =
      AgentEnvironment.scrub_shell_command("env | grep -E '^(ERL_AFLAGS|RELEASE_NODE|RELEASE_COOKIE|AIUR_NODE_NAME|AIUR_AGENT_NODE_NAME|AIUR_COOKIE|AIUR_ERLANG_COOKIE|OTHER_COOKIE)=' | sort")

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"ERL_AFLAGS", "-name aiur@test"},
          {"RELEASE_NODE", "aiur@test"},
          {"RELEASE_COOKIE", "secret"},
          {"AIUR_NODE_NAME", "aiur@test"},
          {"AIUR_AGENT_NODE_NAME", "aiur@test"},
          {"AIUR_COOKIE", "secret"},
          {"AIUR_ERLANG_COOKIE", "secret"},
          {"OTHER_COOKIE", "keep"}
        ]
      )

    assert output == "OTHER_COOKIE=keep\n"
  end
end
