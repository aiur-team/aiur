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

  test "identifies inherited parent log environment names" do
    assert AgentEnvironment.parent_log_env_name?("AIUR_LOGS_ROOT")
    assert AgentEnvironment.parent_log_env_name?("AIUR_AGENT_IR_LOGS_PARENT")

    refute AgentEnvironment.parent_log_env_name?("AIUR_AGENT_WORKSPACE")
    refute AgentEnvironment.parent_log_env_name?("AIUR_DEBUG")
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

  test "scrub_shell_command clears parent log environment before exec" do
    grep_pattern =
      "^(AIUR_LOGS_ROOT|AIUR_AGENT_IR_LOGS_PARENT|AIUR_AGENT_WORKSPACE|AIUR_DEBUG)="

    command =
      AgentEnvironment.scrub_shell_command("env | grep -E '#{grep_pattern}' | sort")

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_LOGS_ROOT", "/home/operator/.aiur/logs/live-session"},
          {"AIUR_AGENT_IR_LOGS_PARENT", "/home/operator/.aiur/logs"},
          {"AIUR_AGENT_WORKSPACE", "/work/aiur/697"},
          {"AIUR_DEBUG", "1"}
        ]
      )

    assert output == "AIUR_AGENT_WORKSPACE=/work/aiur/697\nAIUR_DEBUG=1\n"
  end

  test "scrub_shell_command clears the daemon GitHub token but preserves the agent token" do
    command =
      AgentEnvironment.scrub_shell_command("env | grep -E '^(AIUR_GITHUB_TOKEN|GITHUB_TOKEN)=' | sort")

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_GITHUB_TOKEN", "daemon-secret"},
          {"GITHUB_TOKEN", "agent-token"}
        ]
      )

    assert output == "GITHUB_TOKEN=agent-token\n"
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

  describe "workspace_env/1" do
    # Repos keep `mise.toml` at the root (including aiur itself), so the trust
    # path must be the workspace ROOT — not a hardcoded `elixir/mise.toml`
    # sub-path that does not exist and leaves the real config untrusted (#440).
    test "trusts the workspace root via MISE_TRUSTED_CONFIG_PATHS, not a sub-path" do
      env = AgentEnvironment.workspace_env("/work/aiur/440")

      assert {~c"MISE_TRUSTED_CONFIG_PATHS", trusted} =
               List.keyfind(env, ~c"MISE_TRUSTED_CONFIG_PATHS", 0)

      assert trusted == ~c"/work/aiur/440"
      refute trusted == ~c"/work/aiur/440/elixir/mise.toml"
    end

    test "exposes per-workspace hex/mix homes and the agent-workspace marker" do
      env = AgentEnvironment.workspace_env("/work/aiur/440")

      assert {~c"HEX_HOME", ~c"/work/aiur/440/.aiur-hex"} =
               List.keyfind(env, ~c"HEX_HOME", 0)

      assert {~c"MIX_HOME", ~c"/work/aiur/440/.aiur-mix"} =
               List.keyfind(env, ~c"MIX_HOME", 0)

      assert {~c"AIUR_AGENT_WORKSPACE", ~c"/work/aiur/440"} =
               List.keyfind(env, ~c"AIUR_AGENT_WORKSPACE", 0)

      assert {~c"AIUR_AGENT_MIX_SCHEDULERS", ~c"4"} =
               List.keyfind(env, ~c"AIUR_AGENT_MIX_SCHEDULERS", 0)

      assert {~c"ELIXIR_ERL_OPTIONS", options} = List.keyfind(env, ~c"ELIXIR_ERL_OPTIONS", 0)
      assert to_string(options) =~ "+S 4:4"

      assert {~c"BASH_ENV", hook_path} = List.keyfind(env, ~c"BASH_ENV", 0)
      assert File.regular?(to_string(hook_path))

      assert {~c"AIUR_BUILD_GATE_SLOTS", ~c"2"} =
               List.keyfind(env, ~c"AIUR_BUILD_GATE_SLOTS", 0)

      assert {~c"AIUR_BUILD_START_STAGGER_SECONDS", ~c"0"} =
               List.keyfind(env, ~c"AIUR_BUILD_START_STAGGER_SECONDS", 0)
    end

    test "unsets inherited parent log env while preserving agent workspace env" do
      env = AgentEnvironment.workspace_env("/work/aiur/697")

      assert {~c"AIUR_LOGS_ROOT", false} = List.keyfind(env, ~c"AIUR_LOGS_ROOT", 0)

      assert {~c"AIUR_AGENT_IR_LOGS_PARENT", false} =
               List.keyfind(env, ~c"AIUR_AGENT_IR_LOGS_PARENT", 0)

      assert {~c"AIUR_AGENT_WORKSPACE", ~c"/work/aiur/697"} =
               List.keyfind(env, ~c"AIUR_AGENT_WORKSPACE", 0)

      refute List.keyfind(env, ~c"AIUR_DEBUG", 0)
    end

    test "unsets the daemon GitHub token while preserving the agent token" do
      env = AgentEnvironment.workspace_env("/work/aiur/678")

      assert {~c"AIUR_GITHUB_TOKEN", false} =
               List.keyfind(env, ~c"AIUR_GITHUB_TOKEN", 0)

      refute List.keyfind(env, ~c"GITHUB_TOKEN", 0)
    end

    test "removes the daemon GitHub token from a running Port child" do
      executable = System.find_executable("bash")

      env =
        [
          {~c"AIUR_GITHUB_TOKEN", ~c"daemon-secret"},
          {~c"GITHUB_TOKEN", ~c"agent-token"}
        ] ++ AgentEnvironment.workspace_env("/work/aiur/678")

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            args: [~c"-lc", ~c"printf '%s:%s\n' \"${AIUR_GITHUB_TOKEN-unset}\" \"${GITHUB_TOKEN-unset}\""],
            env: env,
            line: 1_024
          ]
        )

      assert_receive {^port, {:data, {:eol, "unset:agent-token"}}}, 1_000
      assert_receive {^port, {:exit_status, 0}}, 1_000
    end

    test "returns an empty list for a non-binary path so callers can splat safely" do
      assert AgentEnvironment.workspace_env(nil) == []
    end
  end

  describe "workspace_env_export_prefix/1" do
    test "exports MISE_TRUSTED_CONFIG_PATHS pointed at the workspace root" do
      prefix = AgentEnvironment.workspace_env_export_prefix("/work/aiur/440")

      assert prefix =~ "MISE_TRUSTED_CONFIG_PATHS='/work/aiur/440'"
      assert prefix =~ "AIUR_AGENT_MIX_SCHEDULERS='4'"
      assert prefix =~ "ELIXIR_ERL_OPTIONS='+S 4:4'"
      refute prefix =~ "elixir/mise.toml"
    end

    test "returns an empty string for a non-binary path" do
      assert AgentEnvironment.workspace_env_export_prefix(nil) == ""
    end
  end
end
