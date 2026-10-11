defmodule Aiur.Config.RuntimeSandboxTest do
  use Aiur.TestSupport
  alias Aiur.AgentEnvironment
  alias Aiur.Config.{RoutingValue, Schema}
  alias Aiur.Config.Schema.{AgentValidation, Codex, StringOrMap}

  test "local Codex runtime preflights the enabled build-gate root" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-runtime-build-gate")

    previous_gate_dir = Application.get_env(:aiur, :build_gate_dir_override)

    on_exit(fn ->
      case previous_gate_dir do
        nil -> Application.delete_env(:aiur, :build_gate_dir_override)
        path -> Application.put_env(:aiur, :build_gate_dir_override, path)
      end

      File.rm_rf(test_root)
    end)

    workspace = Path.join(test_root, "workspace")
    user_root = Path.join(test_root, "user-root")
    gate_dir = Path.join(test_root, "shared-gate")
    File.mkdir_p!(workspace)
    File.mkdir_p!(user_root)
    Application.put_env(:aiur, :build_gate_dir_override, gate_dir)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace,
      max_concurrent_builds: 2,
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [user_root]
      }
    )

    assert {:ok, runtime_settings} = Config.codex_runtime_settings(workspace)
    assert {:ok, canonical_workspace} = Aiur.PathSafety.canonicalize(workspace)
    assert {:ok, canonical_gate_dir} = Aiur.PathSafety.canonicalize(gate_dir)

    assert runtime_settings.turn_sandbox_policy["writableRoots"] ==
             [
               user_root,
               canonical_workspace,
               AgentEnvironment.package_cache_paths(),
               canonical_gate_dir
             ]
             |> List.flatten()

    assert File.dir?(gate_dir)
    refute Aiur.BuildGate.lock_dir(gate_dir) in runtime_settings.turn_sandbox_policy["writableRoots"]
    assert File.regular?(Path.join(Aiur.BuildGate.lock_dir(gate_dir), "slot-1.lock"))
    assert File.regular?(Path.join(Aiur.BuildGate.lock_dir(gate_dir), "slot-2.lock"))
    assert File.regular?(Path.join(Aiur.BuildGate.lock_dir(gate_dir), "phase-start.lock"))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace,
      max_concurrent_builds: 2,
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [test_root]
      }
    )

    assert {:ok, unsafe_root} = Aiur.PathSafety.canonicalize(test_root)

    assert {:error,
            {:build_gate_unavailable,
             %{
               operation: :separate_lock_namespace,
               path: unsafe_lock_dir,
               reason: {:overlaps_writable_root, ^unsafe_root}
             }}} = Config.codex_runtime_settings(workspace)

    assert unsafe_lock_dir == Aiur.BuildGate.lock_dir(gate_dir)

    invalid_gate_path = Path.join(test_root, "not-a-directory")
    File.write!(invalid_gate_path, "regular file")
    Application.put_env(:aiur, :build_gate_dir_override, invalid_gate_path)

    assert {:error,
            {:build_gate_unavailable,
             %{
               operation: :create_directory,
               path: ^invalid_gate_path,
               reason: :enotdir,
               recovery: recovery
             }}} = Config.codex_runtime_settings(workspace)

    assert recovery =~ "repair"
    assert recovery =~ "max_concurrent_builds: 0"
    assert recovery =~ "build_start_stagger_seconds: 0"
    assert recovery =~ "min_free_memory_mb omitted"

    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_builds: 2,
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    assert {:ok, future_settings} = Config.codex_runtime_settings(workspace)

    assert future_settings.turn_sandbox_policy == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_builds: 0)
    assert {:ok, disabled_settings} = Config.codex_runtime_settings(workspace)
    refute invalid_gate_path in disabled_settings.turn_sandbox_policy["writableRoots"]
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             Aiur.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults and augments workspaceWrite policies" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-runtime-sandbox-branches")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               Aiur.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      configured_root = Path.join(test_root, "configured-extra")
      File.mkdir_p!(configured_root)

      workspace_write_settings = %{
        settings
        | agent: %{
            settings.agent
            | codex: %{
                settings.agent.codex
                | turn_sandbox_policy: %{
                    "type" => "workspaceWrite",
                    "writableRoots" => [configured_root]
                  }
              }
          }
      }

      assert {:ok, configured_default_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(workspace_write_settings)

      assert configured_default_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [configured_root, canonical_workspace_root]
             }

      assert {:ok, workspace_write_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 workspace_write_settings,
                 issue_workspace
               )

      assert {:ok, canonical_issue_workspace} = Aiur.PathSafety.canonicalize(issue_workspace)

      assert workspace_write_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [configured_root, canonical_issue_workspace]
             }

      remote_workspace = "/remote/workspaces/MT-101"

      assert {:ok, remote_workspace_write_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 workspace_write_settings,
                 remote_workspace,
                 remote: true
               )

      assert remote_workspace_write_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [remote_workspace, Path.join(remote_workspace, ".git"), Path.join(remote_workspace, ".agents")]
             }

      read_only_settings = %{
        settings
        | agent: %{
            settings.agent
            | codex: %{
                settings.agent.codex
                | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}
              }
          }
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | agent: %{
            settings.agent
            | codex: %{
                settings.agent.codex
                | thread_sandbox: "danger-full-access",
                  turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
              }
          }
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      danger_settings = %{
        settings
        | agent: %{
            settings.agent
            | codex: %{
                settings.agent.codex
                | thread_sandbox: "danger-full-access",
                  turn_sandbox_policy: nil
              }
          }
      }

      assert {:ok, %{"type" => "dangerFullAccess"}} =
               Schema.resolve_runtime_turn_sandbox_policy(danger_settings, 123)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_thread_sandbox: "danger-full-access",
        codex_turn_sandbox_policy: nil
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)
      assert runtime_settings.thread_sandbox == "danger-full-access"
      assert runtime_settings.turn_sandbox_policy == %{"type" => "dangerFullAccess"}

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_thread_sandbox: "danger-full-access",
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_writable_roots, :not_a_list}}} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 settings,
                 issue_workspace,
                 additional_writable_roots: :not_a_list
               )

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_writable_roots, :not_a_list}}} =
               Config.codex_runtime_settings(
                 issue_workspace,
                 additional_writable_roots: :not_a_list
               )
    after
      File.rm_rf(test_root)
    end
  end
end
