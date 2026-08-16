defmodule Aiur.AgentEnvironmentTest do
  # Not async: every test here mutates process-global `System.put_env` state
  # (including the ELEVENLABS_API_KEY credential case), which raced concurrent
  # BuildGate readers and made `AIUR_BUILD_START_STAGGER_SECONDS` observe another
  # module's value (#1920).
  use ExUnit.Case, async: false

  alias Aiur.AgentEnvironment
  alias Aiur.GitHub.Budget

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
        "env | grep -E '^(ERL_AFLAGS|RELEASE_NODE|RELEASE_COOKIE|AIUR_NODE_NAME|AIUR_AGENT_NODE_NAME|AIUR_COOKIE|AIUR_ERLANG_COOKIE|AIUR_RELEASE_NODE|AIUR_INSTANCE_KEY|AIUR_REPO_ROOT|ROOTDIR|BINDIR|EMU|PROGNAME|OTHER_COOKIE)=' | sort"
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
          {"AIUR_RELEASE_DIR", "/outer/release"},
          {"ROOTDIR", "/outer/release"},
          {"BINDIR", "/outer/release/erts-16.4/bin"},
          {"EMU", "beam"},
          {"PROGNAME", "erl"},
          {"OTHER_COOKIE", "keep"}
        ]
      )

    assert output == "OTHER_COOKIE=keep\n"
  end

  test "scrub_shell_command clears the restart rebuild command bound to the outer checkout" do
    # AIUR_RESTART_BUILD_CMD names one checkout's builder. Inherited by an agent,
    # an inner `aiur restart` runs the OUTER checkout's rebuild against whatever
    # release it is pointed at — the cross-checkout build this guard exists to end.
    command =
      AgentEnvironment.scrub_shell_command("env | grep -E '^(AIUR_RESTART_BUILD_CMD|AIUR_RESTART_BUILD_RECEIPT|AIUR_RESTART_BUILD_VERIFIES|OTHER_KEEP)=' | sort")

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RESTART_BUILD_CMD", "AIUR_REPO_ROOT=/outer/repo /outer/repo/scripts/aiurdev __ensure-build"},
          {"AIUR_RESTART_BUILD_RECEIPT", "/tmp/outer-receipt"},
          {"AIUR_RESTART_BUILD_VERIFIES", "1"},
          {"OTHER_KEEP", "keep"}
        ]
      )

    assert output == "OTHER_KEEP=keep\n"
  end

  test "scrubbed toolchain probe resolves OTP from mise, not the release" do
    release_root = Path.join(System.tmp_dir!(), "aiur-release-#{System.unique_integer([:positive])}")
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    release_bin = Path.join(release_root, "bin")
    expected_inets = :inets |> :code.lib_dir() |> to_string()
    File.mkdir_p!(release_erts_bin)
    File.mkdir_p!(release_bin)
    File.write!(Path.join(release_erts_bin, "erl"), "#!/bin/sh\necho poisoned-release-erl\nexit 86\n")
    File.chmod!(Path.join(release_erts_bin, "erl"), 0o755)
    on_exit(fn -> File.rm_rf!(release_root) end)

    command =
      AgentEnvironment.scrub_shell_command("mise exec -- elixir -e 'IO.puts(:code.lib_dir(:inets)); IO.inspect(Application.ensure_all_started(:inets))'")

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", release_root},
          {"BINDIR", release_erts_bin},
          {"EMU", "beam"},
          {"PROGNAME", "erl"},
          {"PATH", Enum.join([release_erts_bin, release_bin, System.fetch_env!("PATH")], ":")}
        ]
      )

    assert output =~ expected_inets
    assert output =~ "{:ok, [:inets]}"
    refute output =~ release_root
  end

  test "scrub_shell_command preserves unrelated launcher variables and PATH entries" do
    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"))

    unrelated_path = "/opt/user-otp/bin:/usr/local/bin:/usr/bin"

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", "/opt/aiur/release"},
          {"ROOTDIR", "/opt/user-otp"},
          {"BINDIR", "/opt/user-otp/bin"},
          {"EMU", "custom-beam"},
          {"PROGNAME", "custom-erl"},
          {"PATH", unrelated_path},
          {"AIUR_AGENT_BIN", ""}
        ]
      )

    assert ["/opt/user-otp", "/opt/user-otp/bin", "custom-beam", "custom-erl", path] =
             String.split(output, "\n")

    # Login shells may prepend the agent command-guard directory and append
    # system defaults; the caller's unrelated entries must survive in order.
    unrelated_entries = String.split(unrelated_path, ":")
    assert Enum.filter(String.split(path, ":"), &(&1 in unrelated_entries)) == unrelated_entries
  end

  test "scrub_shell_command puts the build gate before other agent commands" do
    command = AgentEnvironment.scrub_shell_command(~s(printf '%s' "$PATH"))

    assert {path, 0} =
             System.cmd("bash", ["-lc", command],
               env: [
                 {"AIUR_BUILD_GATE_BIN", "/workspace/build-bin"},
                 {"AIUR_AGENT_BIN", "/workspace/agent-bin"},
                 {"PATH", "/usr/bin"}
               ]
             )

    assert String.starts_with?(path, "/workspace/build-bin:/workspace/agent-bin:")
  end

  test "scrub_shell_command tracks mixed launcher ownership independently" do
    release_root = "/opt/aiur/release"
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    user_bin = "/opt/user-otp/bin"

    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"))

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", release_root},
          {"BINDIR", user_bin},
          {"EMU", "custom-beam"},
          {"PROGNAME", "custom-erl"},
          {"PATH", Enum.join([release_erts_bin, user_bin, "/usr/bin"], ":")}
        ]
      )

    assert ["", ^user_bin, "custom-beam", "custom-erl", path] = String.split(output, "\n")
    refute path =~ release_erts_bin
    assert path =~ user_bin
  end

  test "scrub_shell_command removes release PATH entries without owned root or bindir" do
    release_root = "/opt/aiur/release"
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    release_bin = Path.join(release_root, "bin")
    user_root = "/opt/user-otp"
    user_bin = Path.join(user_root, "bin")

    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"))

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", user_root},
          {"BINDIR", user_bin},
          {"EMU", "beam"},
          {"PROGNAME", "erl"},
          {"PATH", Enum.join([release_erts_bin, release_bin, user_bin, "/usr/bin"], ":")}
        ]
      )

    # ROOTDIR/BINDIR are user values here, so EMU/PROGNAME (`beam`/`erl`) are
    # NOT release-owned either and must survive — only the PATH cleanup is
    # unconditional once AIUR_RELEASE_DIR establishes the boundary.
    assert [^user_root, ^user_bin, "beam", "erl", path] = String.split(output, "\n")
    refute path =~ release_root
    assert path =~ user_bin
  end

  test "scrub_shell_command scrubs EMU/PROGNAME only when the release launcher owns them" do
    release_root = "/opt/aiur/release"
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])

    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME"))

    # EMU=beam/PROGNAME=erl are generic values; with unrelated ROOTDIR/BINDIR
    # they are user values and must survive the scrub.
    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", "/opt/user-otp"},
          {"BINDIR", "/opt/user-otp/bin"},
          {"EMU", "beam"},
          {"PROGNAME", "erl"}
        ]
      )

    assert output == "/opt/user-otp\n/opt/user-otp/bin\nbeam\nerl"

    # Once ROOTDIR or BINDIR is release-owned, EMU/PROGNAME at the canonical
    # values belong to the release and are scrubbed.
    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", release_root},
          {"BINDIR", release_erts_bin},
          {"EMU", "beam"},
          {"PROGNAME", "erl"}
        ]
      )

    assert output == "\n\n\n"
  end

  test "scrub_shell_command removes trailing-slash release BINDIR and PATH entries" do
    release_root = "/opt/aiur/release"
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    release_bin = Path.join(release_root, "bin")
    user_bin = "/opt/user-otp/bin"

    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"))

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", release_root},
          {"BINDIR", release_erts_bin <> "/"},
          {"EMU", "beam"},
          {"PROGNAME", "erl"},
          {"PATH", Enum.join([release_erts_bin <> "/", release_bin <> "/", user_bin, "/usr/bin"], ":")}
        ]
      )

    # BINDIR with a trailing slash is still release-owned; trailing-slash PATH
    # entries still get filtered, while unrelated user entries are preserved.
    assert ["", "", "", "", path] = String.split(output, "\n")
    refute path =~ release_root
    assert path =~ user_bin
    assert path =~ "/usr/bin"
  end

  test "release launcher scrub runs under a POSIX sh interpreter" do
    release_root = "/opt/aiur/release"
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    release_bin = Path.join(release_root, "bin")
    user_bin = "/opt/user-otp/bin"

    # The release launcher block must stay POSIX-sh portable (dash on Debian
    # CI); `dash` is not installed on every host, so fall back to the system
    # POSIX sh.
    interpreter = System.find_executable("dash") || System.find_executable("sh") || "sh"

    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"))

    {output, 0} =
      System.cmd(interpreter, ["-c", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", release_root},
          {"BINDIR", release_erts_bin},
          {"EMU", "beam"},
          {"PROGNAME", "erl"},
          {"PATH", Enum.join([release_erts_bin, release_bin, user_bin, "/usr/bin"], ":")}
        ]
      )

    assert ["", "", "", "", path] = String.split(output, "\n")
    refute path =~ release_root
    assert path =~ user_bin
  end

  test "scrub_shell_command clears parent log environment before exec" do
    grep_pattern =
      "^(AIUR_LOGS_ROOT|AIUR_AGENT_IR_LOGS_PARENT|AIUR_CI_READINESS_TOKEN|AIUR_AGENT_WORKSPACE|AIUR_DEBUG)="

    command =
      AgentEnvironment.scrub_shell_command("env | grep -E '#{grep_pattern}' | sort")

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_LOGS_ROOT", "/home/operator/.aiur/logs/live-session"},
          {"AIUR_AGENT_IR_LOGS_PARENT", "/home/operator/.aiur/logs"},
          {"AIUR_CI_READINESS_TOKEN", "operator-only"},
          {"AIUR_AGENT_WORKSPACE", "/work/aiur/697"},
          {"AIUR_DEBUG", "1"}
        ]
      )

    assert output == "AIUR_AGENT_WORKSPACE=/work/aiur/697\nAIUR_DEBUG=1\n"
  end

  test "scrub_shell_command clears provider API keys while preserving tracker auth" do
    command =
      AgentEnvironment.scrub_shell_command("env | grep -E '^(DEEPSEEK_API_KEY|OPENROUTER_API_KEY|OPENROUTER_MANAGEMENT_KEY|GITHUB_TOKEN)=' | sort")

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"DEEPSEEK_API_KEY", "deepseek-secret"},
          {"OPENROUTER_API_KEY", "openrouter-secret"},
          {"OPENROUTER_MANAGEMENT_KEY", "management-secret"},
          {"GITHUB_TOKEN", "tracker-token"}
        ]
      )

    assert output == "GITHUB_TOKEN=tracker-token\n"
  end

  # ELEVENLABS_API_KEY is the Stream Deck voice-input credential the daemon reads.
  # It ends in `_API_KEY`, so all three scrub surfaces already cover it; this is
  # the regression guard that keeps it that way.
  test "the ElevenLabs voice-input key is scrubbed from an agent workspace env" do
    previous = System.get_env("ELEVENLABS_API_KEY")
    System.put_env("ELEVENLABS_API_KEY", "elevenlabs-secret")
    on_exit(fn -> restore_env("ELEVENLABS_API_KEY", previous) end)

    assert {~c"ELEVENLABS_API_KEY", false} in AgentEnvironment.workspace_env("/work/aiur/1920")
    assert "ELEVENLABS_API_KEY" in AgentEnvironment.provider_credential_env_names()

    command = AgentEnvironment.scrub_shell_command("env | grep -E '^(ELEVENLABS_API_KEY|GITHUB_TOKEN)=' | sort")

    {output, 0} =
      System.cmd("bash", ["-lc", command], env: [{"ELEVENLABS_API_KEY", "elevenlabs-secret"}, {"GITHUB_TOKEN", "tracker-token"}])

    assert output == "GITHUB_TOKEN=tracker-token\n"

    # The SSH-launch path inlines the same scrub prefix, so the remote export
    # block drops it too.
    prefix = AgentEnvironment.workspace_env_export_prefix("/work/aiur/1920", base_branch: "main")

    {remote_output, 0} =
      System.cmd("bash", ["-lc", "#{prefix}; printf '[%s]' \"${ELEVENLABS_API_KEY:-}\""], env: [{"ELEVENLABS_API_KEY", "elevenlabs-secret"}, {"HOME", "/remote-home"}])

    assert remote_output =~ "[]"
    refute remote_output =~ "elevenlabs-secret"
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

    test "exposes repository-node hex/mix homes and the agent-workspace marker" do
      repo_url = "https://github.com/owner/project.git"
      env = AgentEnvironment.workspace_env("/work/aiur/440", base_branch: "integration", repo_url: repo_url)

      assert {~c"HEX_HOME", hex} =
               List.keyfind(env, ~c"HEX_HOME", 0)

      assert to_string(hex) == Path.join(Aiur.RepoBase.repo_path(repo_url), ".aiur-hex")

      assert {~c"MIX_HOME", mix} =
               List.keyfind(env, ~c"MIX_HOME", 0)

      assert to_string(mix) == Path.join(Aiur.RepoBase.repo_path(repo_url), ".aiur-mix")

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

      assert {~c"AIUR_REAL_GIT", real_git} = List.keyfind(env, ~c"AIUR_REAL_GIT", 0)
      assert is_list(real_git) or real_git == false

      assert {~c"AIUR_AGENT_WORKSPACE", ~c"/work/aiur/440"} =
               List.keyfind(env, ~c"AIUR_AGENT_WORKSPACE", 0)

      assert {~c"AIUR_AGENT_QUOTA_STATE_PATH", ~c"/work/aiur/440/.aiur-runtime/github-quota"} =
               List.keyfind(env, ~c"AIUR_AGENT_QUOTA_STATE_PATH", 0)

      # The guard fingerprints the credential that `gh` actually uses. Passing
      # the daemon credential's key here would merge unrelated App/PAT budgets.
      assert {~c"AIUR_GITHUB_BUDGET_KEY", false} = List.keyfind(env, ~c"AIUR_GITHUB_BUDGET_KEY", 0)
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

      assert {~c"BASH_ENV", hook_path} = List.keyfind(env, ~c"BASH_ENV", 0)
      assert File.regular?(to_string(hook_path))

      assert {~c"AIUR_BUILD_GATE_BIN", ~c"/work/aiur/440/.aiur-runtime/build-bin"} =
               List.keyfind(env, ~c"AIUR_BUILD_GATE_BIN", 0)

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

      assert {~c"AIUR_CI_READINESS_TOKEN", false} =
               List.keyfind(env, ~c"AIUR_CI_READINESS_TOKEN", 0)

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

  describe "workspace_env_export_prefix/1" do
    test "exports home-relative sidecar paths and scrubs operator credentials" do
      repo_url = "https://github.com/owner/project.git"

      prefix =
        AgentEnvironment.workspace_env_export_prefix("/work/aiur/440",
          base_branch: "integration",
          repo_url: repo_url
        )

      assert prefix =~ "MISE_TRUSTED_CONFIG_PATHS='/work/aiur/440'"
      assert prefix =~ "AIUR_AGENT_MIX_SCHEDULERS='4'"
      assert prefix =~ "ELIXIR_ERL_OPTIONS='+S 4:4'"
      assert prefix =~ "AIUR_BASE_BRANCH='integration'"
      assert prefix =~ "HEX_HOME='~/.aiur/repo/owner/project/.aiur-hex'"
      assert prefix =~ "HEX_HOME=\"$HOME/${HEX_HOME#\\~/}\""
      assert prefix =~ "AIUR_REPO_STATE_PATH='~/.aiur/repo/owner/project'"
      assert prefix =~ "AIUR_REPO_STATE_PATH=\"$HOME/${AIUR_REPO_STATE_PATH#\\~/}\""
      assert prefix =~ "AIUR_REAL_GH=\nAIUR_REAL_GIT=\"$(command -v git"
      assert prefix =~ "AIUR_GITHUB_BUDGET_CONSUMER='workspace:/work/aiur/440'"
      assert prefix =~ "AIUR_GITHUB_BUDGET_ROOT='~/.aiur/github-budget'"
      assert prefix =~ "AIUR_GITHUB_BUDGET_BROKER='/work/aiur/440/.aiur-runtime/bin/aiur-github-budget'"
      assert prefix =~ "AIUR_GITHUB_MAX_INFLIGHT=4"
      assert prefix =~ "AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT=2"
      assert prefix =~ "AIUR_GITHUB_REQUESTS_PER_MINUTE=120"
      assert prefix =~ "AIUR_GITHUB_STAGGER_MS=75"
      assert prefix =~ "export AIUR_REAL_GH AIUR_REAL_GIT"
      assert prefix =~ "AIUR_AGENT_BIN='/work/aiur/440/.aiur-runtime/bin'"
      assert prefix =~ "GH_CONFIG_DIR='/work/aiur/440/.aiur-runtime/gh'"
      assert prefix =~ "AIUR_AGENT_QUOTA_STATE_PATH='/work/aiur/440/.aiur-runtime/github-quota'"
      assert prefix =~ "AIUR_AGENT_WORKSPACE='/work/aiur/440'"
      assert prefix =~ "unset AIUR_GITHUB_BUDGET_KEY"
      refute prefix =~ "AIUR_BUILD_GATE_BIN='"
      assert prefix =~ "AIUR_CI_READINESS_TOKEN"
      assert prefix =~ "*_API_KEY"
      refute prefix =~ Aiur.RepoBase.repo_path(repo_url)
      refute prefix =~ "elixir/mise.toml"

      {paths, 0} =
        System.cmd("sh", ["-lc", "#{prefix}; printf '%s|%s|%s|%s' \"$HEX_HOME\" \"$MIX_HOME\" \"$npm_config_cache\" \"$AIUR_REPO_STATE_PATH\""], env: [{"HOME", "/remote-home"}])

      assert paths ==
               "/remote-home/.aiur/repo/owner/project/.aiur-hex|" <>
                 "/remote-home/.aiur/repo/owner/project/.aiur-mix|" <>
                 "/remote-home/.aiur/repo/owner/project/.aiur-npm-cache|" <>
                 "/remote-home/.aiur/repo/owner/project"

      {output, status} =
        System.cmd("bash", ["-c", "false && #{prefix} && printf 'FELL_THROUGH'"],
          env: [{"AIUR_CI_READINESS_TOKEN", "operator-only"}],
          stderr_to_stdout: true
        )

      assert status != 0
      refute output =~ "FELL_THROUGH"

      {output, 0} =
        System.cmd("bash", ["-c", "#{prefix} && printf 'TOKEN=%s' \"${AIUR_CI_READINESS_TOKEN-unset}\""],
          env: [{"AIUR_CI_READINESS_TOKEN", "operator-only"}],
          stderr_to_stdout: true
        )

      assert output == "TOKEN=unset"
    end

    test "returns an empty string for a non-binary path" do
      assert AgentEnvironment.workspace_env_export_prefix(nil) == ""
    end

    test "local export prefixes include build admission while remote prefixes stay gate-free" do
      prefix =
        AgentEnvironment.workspace_env_export_prefix("/work/aiur/440",
          base_branch: "develop",
          build_gate: true
        )

      assert prefix =~ "AIUR_BUILD_GATE_BIN='/work/aiur/440/.aiur-runtime/build-bin'"
      assert prefix =~ "BASH_ENV="
      assert prefix =~ "AIUR_BUILD_GATE_SLOTS='2'"
    end
  end

  # Concurrent agents share the host's /tmp, so two of them staging a comment
  # body at the same generic path clobber each other and one publishes the
  # other ticket's workpad (#1763).
  describe "workspace-private TMPDIR" do
    setup do
      workspace = Path.join(System.tmp_dir!(), "aiur-env-scratch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)
      {:ok, workspace: workspace}
    end

    test "workspace_env/1 points TMPDIR at the workspace's own scratch dir", %{workspace: workspace} do
      env = AgentEnvironment.workspace_env(workspace)
      expected = String.to_charlist(Path.join(workspace, ".aiur-runtime/tmp"))

      assert {~c"TMPDIR", ^expected} = List.keyfind(env, ~c"TMPDIR", 0)
      assert {~c"TMP", ^expected} = List.keyfind(env, ~c"TMP", 0)
      assert {~c"TEMP", ^expected} = List.keyfind(env, ~c"TEMP", 0)
      refute expected == ~c"/tmp"
      assert File.dir?(Path.join(workspace, ".aiur-runtime/tmp"))
    end

    test "workspace_env/1 leaves TMPDIR alone when the scratch dir is unusable", %{workspace: workspace} do
      File.mkdir_p!(Path.join(workspace, ".aiur-runtime"))
      File.write!(Path.join(workspace, ".aiur-runtime/tmp"), "not a directory")

      env = AgentEnvironment.workspace_env(workspace)

      assert List.keyfind(env, ~c"TMPDIR", 0) == nil
    end

    test "the export prefix redirects TMPDIR for the SSH-launch path", %{workspace: workspace} do
      prefix = AgentEnvironment.workspace_env_export_prefix(workspace, base_branch: "develop")

      {resolved, 0} =
        System.cmd("bash", ["-c", "#{prefix} && printf '%s|%s|%s' \"$TMPDIR\" \"$TMP\" \"$TEMP\""], env: [{"TMPDIR", "/tmp"}])

      scratch = Path.join(workspace, ".aiur-runtime/tmp")
      assert resolved == "#{scratch}|#{scratch}|#{scratch}"
      assert File.dir?(scratch)
    end

    # A path whose parent component is a regular file always fails with ENOTDIR,
    # for root as well as an ordinary user — unlike chmod bits, which root
    # ignores, or `/proc`, which only exists on Linux.
    test "the export prefix keeps launching when the scratch dir cannot be created", %{workspace: workspace} do
      File.write!(Path.join(workspace, "blocker"), "regular file")
      unwritable = Path.join(workspace, "blocker/nested")

      prefix = AgentEnvironment.workspace_env_export_prefix(unwritable, base_branch: "develop")

      {resolved, 0} =
        System.cmd("bash", ["-c", "#{prefix} && printf '%s' \"$TMPDIR\""],
          env: [{"TMPDIR", "/tmp"}],
          stderr_to_stdout: true
        )

      assert resolved == "/tmp"
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
