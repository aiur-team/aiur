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
    # Per-instance identity inputs (#431) must be scrubbed so an agent's inner aiur
    # derives its own identity instead of reaping the outer.
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_RELEASE_NODE")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_INSTANCE_KEY")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_REPO_ROOT")

    refute AgentEnvironment.erlang_distribution_env_name?("OTHER_COOKIE")
    refute AgentEnvironment.erlang_distribution_env_name?("PATH")
  end

  test "scrub_shell_command clears Erlang distribution environment before exec" do
    command =
      AgentEnvironment.scrub_shell_command(
        "env | grep -E '^(ERL_AFLAGS|RELEASE_NODE|RELEASE_COOKIE|AIUR_NODE_NAME|AIUR_AGENT_NODE_NAME|AIUR_COOKIE|AIUR_ERLANG_COOKIE|AIUR_RELEASE_NODE|AIUR_INSTANCE_KEY|AIUR_REPO_ROOT|OTHER_COOKIE)=' | sort"
      )

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
          # #431 per-instance identity inputs — must not leak into an inner aiur.
          {"AIUR_RELEASE_NODE", "aiur-kevin-abc1230000@127.0.0.1"},
          {"AIUR_INSTANCE_KEY", "abc1230000"},
          {"AIUR_REPO_ROOT", "/outer/repo"},
          {"OTHER_COOKIE", "keep"}
        ]
      )

    assert output == "OTHER_COOKIE=keep\n"
  end

  test "scrub_shell_command preserves caller exec choice" do
    refute AgentEnvironment.scrub_shell_command("codex app-server") =~ "; exec codex"
    assert AgentEnvironment.scrub_shell_command("codex app-server", exec: true) =~ "; exec codex app-server"
  end

  describe "base_env/1" do
    test "trusts the base mise config via MISE_TRUSTED_CONFIG_PATHS" do
      assert AgentEnvironment.base_env("/tmp/base") == [
               {"MISE_TRUSTED_CONFIG_PATHS", "/tmp/base"}
             ]
    end

    test "returns an empty list for a non-binary path so callers can splat safely" do
      assert AgentEnvironment.base_env(nil) == []
    end
  end
end
