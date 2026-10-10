defmodule Aiur.AgentEnvironment.WorkspaceEnvTest do
  # Not async: every test here mutates process-global `System.put_env` state
  # (including the ELEVENLABS_API_KEY credential case), which raced concurrent
  # BuildGate readers and made `AIUR_BUILD_START_STAGGER_SECONDS` observe another
  # module's value (#1920).
  use ExUnit.Case, async: false

  alias Aiur.{AgentEnvironment, AgentGitHubGuard, BuildGate}
  alias Aiur.GitHub.Budget

  test "the ElevenLabs voice-input key is scrubbed from an agent workspace env" do
    previous = System.get_env("ELEVENLABS_API_KEY")
    System.put_env("ELEVENLABS_API_KEY", "elevenlabs-secret")
    on_exit(fn -> restore_env("ELEVENLABS_API_KEY", previous) end)

    assert {~c"ELEVENLABS_API_KEY", false} in AgentEnvironment.workspace_env("/work/aiur/1920")
    assert "ELEVENLABS_API_KEY" in AgentEnvironment.provider_credential_env_names()

    command = AgentEnvironment.scrub_shell_command("env | grep -E '^(ELEVENLABS_API_KEY|GITHUB_TOKEN)=' | sort")

    {output, 0} =
      System.cmd("bash", ["-lc", command], env: [{"ELEVENLABS_API_KEY", "elevenlabs-secret"}, {"GITHUB_TOKEN", "tracker-token"}])

    # GITHUB_TOKEN is scrubbed alongside the provider key (#2356): the guard
    # reads the credential from its file, not the environment.
    assert output == ""

    # The SSH-launch path inlines the same scrub prefix, so the remote export
    # block drops it too.
    prefix = AgentEnvironment.workspace_env_export_prefix("/work/aiur/1920", base_branch: "main")

    {remote_output, 0} =
      System.cmd("bash", ["-lc", "#{prefix}; printf '[%s]' \"${ELEVENLABS_API_KEY:-}\""], env: [{"ELEVENLABS_API_KEY", "elevenlabs-secret"}, {"HOME", "/remote-home"}])

    assert remote_output =~ "[]"
    refute remote_output =~ "elevenlabs-secret"
  end

  # The GitHub App credentials are the daemon's identity (#2266). This asserts on
  # the RESULTING environment, not on the scrub list, and includes a name that
  # does not exist yet — so a future App credential that is added without being
  # named here still has to be scrubbed for this test to pass.
  test "no GitHub App credential survives into an agent environment" do
    app_env = [
      {"GITHUB_APP_ID", "12345"},
      {"GITHUB_APP_INSTALLATION_ID", "678"},
      {"GITHUB_APP_PRIVATE_KEY_PATH", "/secrets/aiur-app.pem"},
      {"GITHUB_APP_PRIVATE_KEY", "-----BEGIN RSA PRIVATE KEY-----"},
      {"GITHUB_APP_CLIENT_SECRET", "future-app-secret"}
    ]

    previous = Enum.map(app_env, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(app_env, fn {name, value} -> System.put_env(name, value) end)
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)

    # 1. Port.open launch path: every App name is unset for the child, and the
    #    bot PAT the agent legitimately publishes with is untouched.
    workspace_env = AgentEnvironment.workspace_env("/work/aiur/2266")

    Enum.each(app_env, fn {name, _value} ->
      assert {String.to_charlist(name), false} in workspace_env, "#{name} is not unset for the agent process"
    end)

    # The bot PAT the agent legitimately publishes with is now ALSO unset for
    # the agent process (#2356) — the guard reads it from the credential file
    # instead of the environment.
    assert {~c"GITHUB_TOKEN", false} in workspace_env

    # 2. Shell scrub path: run it and read back what actually survives. The
    #    bot PAT agents legitimately publish with is also scrubbed (#2356) —
    #    the guard reads it from the token file instead of the environment.
    command =
      AgentEnvironment.scrub_shell_command("env | grep -E '^(GITHUB_APP_|GITHUB_TOKEN=)' | sort")

    {output, _status} = System.cmd("bash", ["-lc", command], env: app_env ++ [{"GITHUB_TOKEN", "bot-pat"}])

    assert output == ""

    Enum.each(app_env, fn {_name, value} -> refute output =~ value end)

    # 3. SSH-launch path inlines the same prefix.
    prefix = AgentEnvironment.workspace_env_export_prefix("/work/aiur/2266", base_branch: "main")

    {remote_output, 0} =
      System.cmd("bash", ["-lc", "#{prefix}; env | grep -c '^GITHUB_APP_' || true"], env: app_env ++ [{"HOME", "/remote-home"}])

    assert String.trim(remote_output) == "0"
  end

  # #2356 acceptance: `env | grep -i -E 'GITHUB_TOKEN|GH_TOKEN'` in an agent
  # shell returns nothing, on every launch surface. The agent carries only the
  # token-file PATH the `gh` guard reads; the raw credential is never in the
  # environment where a bare curl or a dependency build script could inherit it.
  test "no raw GitHub credential survives into an agent environment" do
    credentials = [
      {"GITHUB_TOKEN", "bot-pat"},
      {"GH_TOKEN", "gh-pat"},
      {"GH_ENTERPRISE_TOKEN", "enterprise-gh-token"},
      {"GITHUB_ENTERPRISE_TOKEN", "enterprise-github-token"}
    ]

    previous = Enum.map(credentials, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(credentials, fn {name, value} -> System.put_env(name, value) end)
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)

    # 1. Port.open launch path: every name is unset for the child, and the
    #    credential file path the guard reads is exported instead.
    env = AgentEnvironment.workspace_env("/work/aiur/2356")

    Enum.each(credentials, fn {name, _value} ->
      assert {String.to_charlist(name), false} in env, "#{name} is not unset for the agent process"
    end)

    assert {~c"AIUR_GITHUB_CREDENTIAL_FILE", token_file} = List.keyfind(env, ~c"AIUR_GITHUB_CREDENTIAL_FILE", 0)
    assert List.to_string(token_file) == AgentGitHubGuard.agent_token_path()

    # 2. Shell scrub path: run it and confirm nothing matches the acceptance grep.
    command = AgentEnvironment.scrub_shell_command("env | grep -i -E 'GITHUB_TOKEN|GH_TOKEN' | sort")

    {output, _status} = System.cmd("bash", ["-lc", command], env: credentials)

    assert output == ""

    # 3. SSH-launch path inlines the same prefix and exports the token-file path.
    prefix = AgentEnvironment.workspace_env_export_prefix("/work/aiur/2356", base_branch: "main")

    assert prefix =~ "AIUR_GITHUB_CREDENTIAL_FILE"
    refute prefix =~ "export GITHUB_TOKEN"

    {remote_output, 0} =
      System.cmd("bash", ["-lc", "#{prefix}; env | grep -i -c -E 'GITHUB_TOKEN|GH_TOKEN' || true"],
        env: credentials ++ [{"HOME", "/remote-home"}],
        stderr_to_stdout: true
      )

    assert String.trim(remote_output) == "0"
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

    test "exposes repository-node hex/mix homes and the agent-workspace marker" do
      repo_url = "https://github.com/owner/project.git"
      env = AgentEnvironment.workspace_env("/work/aiur/440", base_branch: "integration", repo_url: repo_url, github_budget_identity: "aiur-bot")
      repo_state = Aiur.RepoBase.repo_path(repo_url)
      hex_home = Path.join(repo_state, ".aiur-hex")
      mix_home = Path.join(repo_state, ".aiur-mix")
      npm_cache = Path.join(repo_state, ".aiur-npm-cache")

      assert {~c"HEX_HOME", hex} =
               List.keyfind(env, ~c"HEX_HOME", 0)

      assert to_string(hex) == hex_home

      assert {~c"MIX_HOME", mix} =
               List.keyfind(env, ~c"MIX_HOME", 0)

      assert to_string(mix) == mix_home

      assert {~c"npm_config_cache", npm} =
               List.keyfind(env, ~c"npm_config_cache", 0)

      assert to_string(npm) == npm_cache

      assert {~c"AIUR_REPO_STATE_PATH", state_path} =
               List.keyfind(env, ~c"AIUR_REPO_STATE_PATH", 0)

      assert to_string(state_path) == Aiur.RepoBase.repo_path(repo_url)

      assert {~c"AIUR_AGENT_BIN", ~c"/work/aiur/440/.aiur-runtime/bin"} =
               List.keyfind(env, ~c"AIUR_AGENT_BIN", 0)

      # Dispatched agents must not inherit the operator's `gh` config dir: that
      # is where the keyring account lives, and that account is the sole branch
      # protection bypass actor. Point them at an agent-private dir instead so
      # `env -u GITHUB_TOKEN -u GH_TOKEN gh` has nothing to fall back to.
      assert {~c"GH_CONFIG_DIR", ~c"/work/aiur/440/.aiur-runtime/gh"} =
               List.keyfind(env, ~c"GH_CONFIG_DIR", 0)

      assert {~c"AIUR_REAL_GH", real_gh} = List.keyfind(env, ~c"AIUR_REAL_GH", 0)
      assert is_list(real_gh) or real_gh == false

      assert {~c"AIUR_GITHUB_LABEL_PREFIX", ~c"agent"} =
               List.keyfind(env, ~c"AIUR_GITHUB_LABEL_PREFIX", 0)

      # #2073 U6: the `gh` guard files a cached response under a resource
      # identity, so it needs the repository the agent was dispatched against.
      # A tracker with no GitHub slug unsets it, which leaves the guard unable
      # to name a resource and therefore caching nothing — the right outcome.
      assert {~c"AIUR_GITHUB_REPO", slug} = List.keyfind(env, ~c"AIUR_GITHUB_REPO", 0)
      assert slug == false or (is_list(slug) and List.to_string(slug) =~ ~r{\A[\w.-]+/[\w.-]+\z})

      custom_env =
        AgentEnvironment.workspace_env("/work/aiur/440",
          base_branch: "integration",
          repo_url: repo_url,
          label_prefix: "team",
          github_budget_identity: "aiur-bot"
        )

      assert {~c"AIUR_GITHUB_LABEL_PREFIX", ~c"team"} =
               List.keyfind(custom_env, ~c"AIUR_GITHUB_LABEL_PREFIX", 0)

      assert {~c"AIUR_REAL_GIT", real_git} = List.keyfind(env, ~c"AIUR_REAL_GIT", 0)
      assert is_list(real_git) or real_git == false

      assert {~c"AIUR_AGENT_WORKSPACE", ~c"/work/aiur/440"} =
               List.keyfind(env, ~c"AIUR_AGENT_WORKSPACE", 0)

      assert {~c"AIUR_AGENT_QUOTA_STATE_PATH", ~c"/work/aiur/440/.aiur-runtime/github-quota"} =
               List.keyfind(env, ~c"AIUR_AGENT_QUOTA_STATE_PATH", 0)

      # The wrapper hashes the current token separately and receives the stable
      # machine-user identity it publishes as.
      assert {~c"AIUR_GITHUB_BUDGET_KEY", false} = List.keyfind(env, ~c"AIUR_GITHUB_BUDGET_KEY", 0)

      expected_publication_key = Budget.identity_key("machine_user:primary:aiur-bot") |> String.to_charlist()

      assert {~c"AIUR_GITHUB_BUDGET_IDENTITY_KEY", ^expected_publication_key} =
               List.keyfind(env, ~c"AIUR_GITHUB_BUDGET_IDENTITY_KEY", 0)

      assert {~c"AIUR_GITHUB_BUDGET_ROOT", budget_root} = List.keyfind(env, ~c"AIUR_GITHUB_BUDGET_ROOT", 0)
      assert to_string(budget_root) == Budget.state_dir()

      assert {~c"AIUR_GITHUB_BUDGET_BROKER", ~c"/work/aiur/440/.aiur-runtime/bin/aiur-github-budget"} =
               List.keyfind(env, ~c"AIUR_GITHUB_BUDGET_BROKER", 0)

      assert {~c"AIUR_GITHUB_BUDGET_CONSUMER", ~c"workspace:/work/aiur/440"} =
               List.keyfind(env, ~c"AIUR_GITHUB_BUDGET_CONSUMER", 0)

      assert {~c"AIUR_GITHUB_MAX_INFLIGHT", ~c"4"} = List.keyfind(env, ~c"AIUR_GITHUB_MAX_INFLIGHT", 0)
      assert {~c"AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT", ~c"2"} = List.keyfind(env, ~c"AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT", 0)
      assert {~c"AIUR_GITHUB_REQUESTS_PER_MINUTE", ~c"120"} = List.keyfind(env, ~c"AIUR_GITHUB_REQUESTS_PER_MINUTE", 0)
      assert {~c"AIUR_GITHUB_STAGGER_MS", ~c"75"} = List.keyfind(env, ~c"AIUR_GITHUB_STAGGER_MS", 0)

      assert {~c"AIUR_BASE_BRANCH", ~c"integration"} =
               List.keyfind(env, ~c"AIUR_BASE_BRANCH", 0)

      assert {~c"AIUR_AGENT_MIX_SCHEDULERS", ~c"4"} =
               List.keyfind(env, ~c"AIUR_AGENT_MIX_SCHEDULERS", 0)

      assert {~c"ELIXIR_ERL_OPTIONS", options} = List.keyfind(env, ~c"ELIXIR_ERL_OPTIONS", 0)
      assert to_string(options) =~ "+S 4:4"

      # The only permitted BASH_ENV is Aiur's immutable build-admission hook;
      # an operator-provided value is replaced at the launch boundary.
      assert {~c"BASH_ENV", build_gate_hook} = List.keyfind(env, ~c"BASH_ENV", 0)
      assert to_string(build_gate_hook) == BuildGate.hook_path()
      assert {~c"ENV", false} = List.keyfind(env, ~c"ENV", 0)
      assert {~c"ZDOTDIR", ~c"/dev/null"} = List.keyfind(env, ~c"ZDOTDIR", 0)

      assert {~c"AIUR_BUILD_GATE_BIN", ~c"/work/aiur/440/.aiur-runtime/build-bin"} =
               List.keyfind(env, ~c"AIUR_BUILD_GATE_BIN", 0)

      assert {~c"AIUR_BUILD_GATE_SLOTS", slots_value} =
               List.keyfind(env, ~c"AIUR_BUILD_GATE_SLOTS", 0)

      assert to_string(slots_value) == Integer.to_string(Aiur.Config.max_concurrent_builds())

      assert {~c"AIUR_BUILD_START_STAGGER_SECONDS", ~c"0"} =
               List.keyfind(env, ~c"AIUR_BUILD_START_STAGGER_SECONDS", 0)
    end

    test "keeps a stable publication budget identity when the bot account is unset" do
      env =
        AgentEnvironment.workspace_env("/work/aiur/440",
          base_branch: "integration",
          repo_url: "https://github.com/owner/project.git",
          github_budget_identity: nil
        )

      expected_key = Budget.identity_key("machine_user:primary:primary") |> String.to_charlist()

      assert {~c"AIUR_GITHUB_BUDGET_IDENTITY_KEY", ^expected_key} =
               List.keyfind(env, ~c"AIUR_GITHUB_BUDGET_IDENTITY_KEY", 0)
    end

    test "unsets inherited parent log env while preserving agent workspace env" do
      env = AgentEnvironment.workspace_env("/work/aiur/697")

      assert {~c"AIUR_LOGS_ROOT", false} = List.keyfind(env, ~c"AIUR_LOGS_ROOT", 0)

      assert {~c"AIUR_AGENT_IR_LOGS_PARENT", false} =
               List.keyfind(env, ~c"AIUR_AGENT_IR_LOGS_PARENT", 0)

      assert {~c"AIUR_CI_READINESS_TOKEN", false} =
               List.keyfind(env, ~c"AIUR_CI_READINESS_TOKEN", 0)

      for name <- ~w(ERL_LIBS ERL_CRASH_DUMP ERL_CRASH_DUMP_SECONDS) do
        assert {String.to_charlist(name), false} in env
      end

      assert {~c"AIUR_AGENT_WORKSPACE", ~c"/work/aiur/697"} =
               List.keyfind(env, ~c"AIUR_AGENT_WORKSPACE", 0)

      refute List.keyfind(env, ~c"AIUR_DEBUG", 0)
    end

    test "explicitly unsets provider credentials from local agent ports" do
      env = AgentEnvironment.workspace_env("/work/aiur/1440")

      for name <- ~w(DEEPSEEK_API_KEY MOONSHOT_API_KEY OPENROUTER_API_KEY OPENROUTER_MANAGEMENT_KEY) do
        assert {String.to_charlist(name), false} in env
      end
    end

    test "returns an empty list for a non-binary path so callers can splat safely" do
      assert AgentEnvironment.workspace_env(nil) == []
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
