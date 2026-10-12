defmodule Aiur.Config.SandboxPolicyTest do
  use Aiur.TestSupport
  alias Aiur.AgentEnvironment
  alias Aiur.Config.{RoutingValue, Schema}
  alias Aiur.Config.Schema.{AgentValidation, Codex, StringOrMap}

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{linear: %{api_key: "$#{empty_secret_env}"}},
               workspace: %{root: "$#{missing_workspace_env}"},
               agent: %{codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}}
             })

    assert settings.tracker.linear.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "aiur_workspaces")

    assert settings.agent.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{linear: %{api_key: "$#{missing_secret_env}"}},
               workspace: %{root: ""}
             })

    assert settings.tracker.linear.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "aiur_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             agent: %Schema.Agent{codex: %Codex{turn_sandbox_policy: explicit_policy}},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               agent: %Schema.Agent{codex: %Codex{turn_sandbox_policy: explicit_policy}},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["/tmp/explicit", Path.expand("/tmp/workspace")]
           }

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             agent: %Schema.Agent{codex: %Codex{turn_sandbox_policy: nil}},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "aiur_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               agent: %Schema.Agent{codex: %Codex{turn_sandbox_policy: nil}},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             agent: %Schema.Agent{
               codex: %Codex{thread_sandbox: "danger-full-access", turn_sandbox_policy: nil}
             },
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == %{"type" => "dangerFullAccess"}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             agent: %Schema.Agent{
               codex: %Codex{
                 thread_sandbox: "danger-full-access",
                 turn_sandbox_policy: explicit_policy
               }
             },
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.aiur-workspaces"},
               agent: %{codex: %{}}
             })

    assert settings.workspace.root == "~/.aiur-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.aiur-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.aiur-workspaces", "~/.aiur-workspaces/.git", "~/.aiur-workspaces/.agents"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution augments explicit workspaceWrite policies" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-runtime-sandbox")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      configured_root = Path.join(test_root, "configured-extra")
      File.mkdir_p!(issue_workspace)
      File.mkdir_p!(configured_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [configured_root],
          networkAccess: true
        }
      )

      repo_url = "https://github.com/owner/project.git"
      repo_state = Aiur.RepoBase.repo_path(repo_url)

      sidecar_roots = [
        Path.join(repo_state, ".aiur-hex"),
        Path.join(repo_state, ".aiur-mix"),
        Path.join(repo_state, ".aiur-npm-cache")
      ]

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace, repo_url: repo_url)
      assert {:ok, canonical_issue_workspace} = Aiur.PathSafety.canonicalize(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" =>
                 [
                   configured_root,
                   canonical_issue_workspace,
                   sidecar_roots,
                   Aiur.BuildGate.gate_dir()
                 ]
                 |> List.flatten(),
               "networkAccess" => true
             }

      assert {:ok, remote_settings} =
               Config.codex_runtime_settings(issue_workspace, remote: true, repo_url: repo_url)

      assert remote_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [
                 issue_workspace,
                 Path.join(issue_workspace, ".git"),
                 Path.join(issue_workspace, ".agents")
               ],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace, repo_url: repo_url)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "configured workspaceWrite roots must exist and be writable directories" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-configured-sandbox-roots")

    File.mkdir_p!(test_root)

    on_exit(fn ->
      File.chmod(test_root, 0o755)
      Aiur.TestCleanup.rm_rf!(test_root)
    end)

    nonexistent_root = Path.join(test_root, "does-not-exist")

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [nonexistent_root]
      }
    )

    assert {:error, {:unsafe_turn_sandbox_policy, root_error}} = Config.validate!()
    assert inspect(root_error) =~ nonexistent_root
    assert inspect(root_error) =~ "agent.codex.turn_sandbox_policy.writableRoots"

    regular_file = Path.join(test_root, "regular-file")
    File.write!(regular_file, "not a directory")

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [regular_file]
      }
    )

    assert {:error, {:unsafe_turn_sandbox_policy, regular_file_error}} = Config.validate!()
    assert inspect(regular_file_error) =~ regular_file
    assert inspect(regular_file_error) =~ "not_a_directory"

    read_only_root = Path.join(test_root, "read-only")
    File.mkdir_p!(read_only_root)
    File.chmod!(read_only_root, 0o555)

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [read_only_root]
      }
    )

    assert {:error, {:unsafe_turn_sandbox_policy, read_only_error}} = Config.validate!()
    assert inspect(read_only_error) =~ read_only_root
    assert inspect(read_only_error) =~ "not_writable"

    File.chmod!(read_only_root, 0o755)
    valid_root = Path.join(test_root, "valid")
    File.mkdir_p!(valid_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [valid_root]
      }
    )

    assert :ok = Config.validate!()
  end

  test "local runtime derives the enabled GitHub budget root exactly once" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-runtime-budget-root")

    workspace = Path.join(test_root, "workspace")
    budget_root = Path.join(test_root, "github-budget")
    File.mkdir_p!(workspace)

    previous_enabled = Application.get_env(:aiur, :github_budget_enabled?)
    previous_root = Application.get_env(:aiur, :github_budget_dir)

    on_exit(fn ->
      if is_nil(previous_enabled),
        do: Application.delete_env(:aiur, :github_budget_enabled?),
        else: Application.put_env(:aiur, :github_budget_enabled?, previous_enabled)

      if is_nil(previous_root),
        do: Application.delete_env(:aiur, :github_budget_dir),
        else: Application.put_env(:aiur, :github_budget_dir, previous_root)

      Aiur.TestCleanup.rm_rf!(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace)
    Application.put_env(:aiur, :github_budget_enabled?, true)
    Application.put_env(:aiur, :github_budget_dir, budget_root)

    assert {:ok, local_settings} = Config.codex_runtime_settings(workspace)
    roots = local_settings.turn_sandbox_policy["writableRoots"]
    assert Enum.count(roots, &(&1 == budget_root)) == 1
    assert File.dir?(budget_root)

    assert {:ok, remote_settings} = Config.codex_runtime_settings("/remote/workspace", remote: true)
    refute budget_root in remote_settings.turn_sandbox_policy["writableRoots"]

    Application.put_env(:aiur, :github_budget_enabled?, false)
    assert {:ok, disabled_settings} = Config.codex_runtime_settings(workspace)
    refute budget_root in disabled_settings.turn_sandbox_policy["writableRoots"]
  end

  test "generated local sandbox policy admits package-manager cache-miss writes only to sidecars" do
    test_id = System.unique_integer([:positive])
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-package-cache-sandbox")
    repo_url = "https://github.com/owner/cache-miss-#{test_id}.git"
    repo_state = Aiur.RepoBase.repo_path(repo_url)

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace)

      expected_sidecar_roots = [
        Path.join(repo_state, ".aiur-hex"),
        Path.join(repo_state, ".aiur-mix"),
        Path.join(repo_state, ".aiur-npm-cache")
      ]

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(workspace, repo_url: repo_url)
      writable_roots = runtime_settings.turn_sandbox_policy["writableRoots"]
      agent_env = AgentEnvironment.workspace_env(workspace, repo_url: repo_url)
      env_map = Map.new(agent_env, fn {name, value} -> {to_string(name), value} end)
      hex_home = env_map["HEX_HOME"] |> to_string()
      mix_home = env_map["MIX_HOME"] |> to_string()
      npm_cache = env_map["npm_config_cache"] |> to_string()
      sidecar_roots = [hex_home, mix_home, npm_cache]

      assert sidecar_roots == expected_sidecar_roots
      assert Enum.all?(sidecar_roots, &(&1 in writable_roots))
      refute repo_state in writable_roots
      refute Path.join(repo_state, "latest") in writable_roots
      refute Path.join(repo_state, "meta") in writable_roots

      Enum.each(writable_roots, &File.mkdir_p!/1)
      File.mkdir_p!(Path.join(repo_state, "meta"))

      env =
        Enum.flat_map(agent_env, fn
          {name, value} when is_list(name) and is_list(value) -> [{to_string(name), to_string(value)}]
          _unset -> []
        end)

      command = """
      mkdir -p "$HEX_HOME/packages/hexpm" "$MIX_HOME/archives" "$npm_config_cache/_cacache"
      printf package > "$HEX_HOME/packages/hexpm/cache-miss.tar"
      printf index > "$HEX_HOME/cache.ets"
      printf archive > "$MIX_HOME/archives/hex.ez"
      printf npm > "$npm_config_cache/_cacache/cache-miss"
      if printf denied > "$AIUR_REPO_STATE_PATH/meta/denied" 2>/dev/null; then exit 70; fi
      """

      case System.find_executable("bwrap") do
        nil ->
          :ok

        bwrap ->
          bind_args = Enum.flat_map(writable_roots, &["--bind", &1, &1])

          assert {output, 0} =
                   System.cmd(
                     bwrap,
                     ["--die-with-parent", "--ro-bind", "/", "/"] ++
                       bind_args ++ ["--chdir", workspace, "--", "/bin/sh", "-c", command],
                     env: env,
                     stderr_to_stdout: true
                   )

          assert output =~ "Read-only file system"

          assert File.read!(Path.join(hex_home, "packages/hexpm/cache-miss.tar")) == "package"
          assert File.read!(Path.join(hex_home, "cache.ets")) == "index"
          assert File.read!(Path.join(mix_home, "archives/hex.ez")) == "archive"
          assert File.read!(Path.join(npm_cache, "_cacache/cache-miss")) == "npm"
          refute File.exists?(Path.join(repo_state, "meta/denied"))
      end
    after
      File.rm_rf(test_root)
      File.rm_rf(repo_state)
    end
  end
end
