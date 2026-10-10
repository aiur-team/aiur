defmodule Aiur.AgentEnvironment.WorkspaceEnvExportTest do
  # Not async: every test here mutates process-global `System.put_env` state
  # (including the ELEVENLABS_API_KEY credential case), which raced concurrent
  # BuildGate readers and made `AIUR_BUILD_START_STAGGER_SECONDS` observe another
  # module's value (#1920).
  use ExUnit.Case, async: false

  alias Aiur.AgentEnvironment
  alias Aiur.GitHub.Budget

  describe "workspace_env_export_prefix/1" do
    test "exports home-relative sidecar paths and scrubs operator credentials" do
      repo_url = "https://github.com/owner/project.git"

      prefix =
        AgentEnvironment.workspace_env_export_prefix("/work/aiur/440",
          base_branch: "integration",
          repo_url: repo_url,
          github_budget_identity: "aiur-bot"
        )

      assert prefix =~ "MISE_TRUSTED_CONFIG_PATHS='/work/aiur/440'"
      assert prefix =~ "AIUR_AGENT_MIX_SCHEDULERS='4'"
      assert prefix =~ "ELIXIR_ERL_OPTIONS='+S 4:4'"
      assert prefix =~ "AIUR_BASE_BRANCH='integration'"
      assert prefix =~ "HEX_HOME='~/.aiur/repo/owner/project/.aiur-hex'"
      assert prefix =~ "HEX_HOME=\"$HOME/${HEX_HOME#\\~/}\""
      assert prefix =~ "AIUR_REPO_STATE_PATH='~/.aiur/repo/owner/project'"
      assert prefix =~ "AIUR_REPO_STATE_PATH=\"$HOME/${AIUR_REPO_STATE_PATH#\\~/}\""
      assert prefix =~ "AIUR_REAL_GH=\nAIUR_REAL_GIT='"
      refute prefix =~ "command -v git"
      assert prefix =~ "AIUR_GITHUB_LABEL_PREFIX='agent'"
      # A remote worker keeps its own budget root, and therefore its own state
      # cache shared with the other agents on that host — the same sharing
      # boundary the budget broker already draws.
      assert prefix =~ ~r{export AIUR_GITHUB_REPO='[\w.-]+/[\w.-]+'\n|unset AIUR_GITHUB_REPO\n}
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
      assert prefix =~ "export AIUR_GITHUB_BUDGET_IDENTITY_KEY='#{Budget.identity_key("machine_user:primary:aiur-bot")}'"
      refute prefix =~ "AIUR_BUILD_GATE_BIN='"
      assert prefix =~ "AIUR_CI_READINESS_TOKEN"
      assert prefix =~ "*_API_KEY"
      refute prefix =~ Aiur.RepoBase.repo_path(repo_url)
      refute prefix =~ "elixir/mise.toml"

      custom_prefix =
        AgentEnvironment.workspace_env_export_prefix("/work/aiur/440",
          base_branch: "integration",
          repo_url: repo_url,
          label_prefix: "team",
          github_budget_identity: "aiur-bot"
        )

      assert custom_prefix =~ "AIUR_GITHUB_LABEL_PREFIX='team'"

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
      assert prefix =~ "AIUR_BUILD_GATE_SLOTS='#{Aiur.Config.max_concurrent_builds()}'"
    end
  end

  # Concurrent agents share the host's /tmp, so two of them staging a comment
  # body at the same generic path clobber each other and one publishes the
  # other ticket's workpad (#1763).
  describe "workspace-private TMPDIR" do
    setup do
      workspace = Aiur.TestSupport.tmp_root!("aiur-env-scratch")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)
      {:ok, workspace: workspace}
    end

    test "workspace_env/1 points TMPDIR at the workspace's own scratch dir", %{workspace: workspace} do
      env = AgentEnvironment.workspace_env(workspace)
      expected = String.to_charlist(Path.join(workspace, ".aiur-runtime/tmp"))
      expected_prefix = String.to_charlist(Path.join(workspace, ".aiur-runtime/tmp/zsh-"))

      assert {~c"TMPDIR", ^expected} = List.keyfind(env, ~c"TMPDIR", 0)
      assert {~c"TMP", ^expected} = List.keyfind(env, ~c"TMP", 0)
      assert {~c"TEMP", ^expected} = List.keyfind(env, ~c"TEMP", 0)
      assert {~c"TMPPREFIX", ^expected_prefix} = List.keyfind(env, ~c"TMPPREFIX", 0)
      refute expected == ~c"/tmp"
      assert File.dir?(Path.join(workspace, ".aiur-runtime/tmp"))
    end

    test "workspace_env/1 leaves TMPDIR alone when the scratch dir is unusable", %{workspace: workspace} do
      File.mkdir_p!(Path.join(workspace, ".aiur-runtime"))
      File.write!(Path.join(workspace, ".aiur-runtime/tmp"), "not a directory")

      env = AgentEnvironment.workspace_env(workspace)

      assert List.keyfind(env, ~c"TMPDIR", 0) == nil
      assert List.keyfind(env, ~c"TMPPREFIX", 0) == nil
    end

    test "local agent zsh heredocs use private scratch when the inherited temp path is unusable", %{
      workspace: workspace
    } do
      blocked = Path.join(workspace, "blocked")
      File.write!(blocked, "regular file")
      scratch = AgentEnvironment.workspace_env(workspace)

      temp_env =
        scratch
        |> Enum.filter(fn {name, _} -> name in [~c"TMPDIR", ~c"TMP", ~c"TEMP", ~c"TMPPREFIX"] end)
        |> Map.new(fn {name, value} -> {to_string(name), to_string(value)} end)

      {output, 0} =
        System.cmd("zsh", ["-c", "wc -c <<EOF\nworkpad\nEOF"],
          env: [
            {"TMPDIR", temp_env["TMPDIR"]},
            {"TMPPREFIX", Map.get(temp_env, "TMPPREFIX", Path.join(blocked, "zsh-"))}
          ],
          stderr_to_stdout: true
        )

      assert output == "8\n"
    end

    test "the export prefix redirects TMPDIR for the SSH-launch path", %{workspace: workspace} do
      prefix = AgentEnvironment.workspace_env_export_prefix(workspace, base_branch: "develop")

      {resolved, 0} =
        System.cmd("bash", ["-c", "#{prefix} && printf '%s|%s|%s|%s' \"$TMPDIR\" \"$TMP\" \"$TEMP\" \"$TMPPREFIX\""], env: [{"TMPDIR", "/tmp"}])

      scratch = Path.join(workspace, ".aiur-runtime/tmp")
      assert resolved == "#{scratch}|#{scratch}|#{scratch}|#{scratch}/zsh-"
      assert File.dir?(scratch)
    end

    test "SSH agent zsh heredocs use private scratch when the inherited temp path is unusable", %{
      workspace: workspace
    } do
      blocked = Path.join(workspace, "blocked")
      File.write!(blocked, "regular file")
      prefix = AgentEnvironment.workspace_env_export_prefix(workspace, base_branch: "develop")

      {output, 0} =
        System.cmd("bash", ["-c", "#{prefix} && zsh -c 'wc -c <<EOF\nworkpad\nEOF'"],
          env: [{"TMPPREFIX", Path.join(blocked, "zsh-")}],
          stderr_to_stdout: true
        )

      assert output == "8\n"
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
end
