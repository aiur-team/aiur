defmodule Aiur.Config.TurnSandboxRootsTest do
  use Aiur.TestSupport

  alias Aiur.AgentEnvironment
  alias Aiur.BuildGate
  alias Aiur.Config
  alias Aiur.Config.Schema
  alias Aiur.GitHub.Budget

  setup do
    root = Aiur.TestSupport.tmp_root!("turn-sandbox-roots")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    keys = [:github_budget_enabled?, :github_budget_dir, :turn_sandbox_root_contributors]
    previous = Map.new(keys, &{&1, Application.fetch_env(:aiur, &1)})
    Application.put_env(:aiur, :github_budget_enabled?, true)
    Application.put_env(:aiur, :github_budget_dir, Path.join(root, "budget"))
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), workspace_root: workspace)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)

      File.rm_rf!(root)
    end)

    {:ok, workspace: workspace, root: root}
  end

  # Characterization guards intentionally pass before the contributor extraction.
  test "local roots retain base, package, budget and gate order", %{workspace: workspace} do
    assert {:ok, base} = Schema.resolve_runtime_turn_sandbox_policy(Config.settings!(), workspace)
    assert {:ok, settings} = Config.codex_runtime_settings(workspace)

    assert settings.turn_sandbox_policy["writableRoots"] ==
             base["writableRoots"] ++ AgentEnvironment.package_cache_paths([]) ++ [Budget.state_dir(), BuildGate.gate_dir()]
  end

  test "remote roots remain the base policy", %{workspace: workspace} do
    assert {:ok, base} = Schema.resolve_runtime_turn_sandbox_policy(Config.settings!(), workspace, remote: true)
    assert {:ok, settings} = Config.codex_runtime_settings(workspace, remote: true)
    assert settings.turn_sandbox_policy == base
  end

  test "disabled budget contributes no root", %{workspace: workspace} do
    Application.put_env(:aiur, :github_budget_enabled?, false)
    assert {:ok, base} = Schema.resolve_runtime_turn_sandbox_policy(Config.settings!(), workspace)
    assert {:ok, settings} = Config.codex_runtime_settings(workspace)

    assert settings.turn_sandbox_policy["writableRoots"] ==
             base["writableRoots"] ++ AgentEnvironment.package_cache_paths([]) ++ [BuildGate.gate_dir()]
  end

  test "gate preparation error is propagated", %{workspace: workspace, root: root} do
    gate = Path.join(root, "gate-file")
    File.write!(gate, "not a directory")
    Application.put_env(:aiur, :build_gate_dir_override, gate)
    settings = Config.settings!()

    gate_opts = [
      slots: settings.agent.max_concurrent_builds,
      stagger_seconds: settings.agent.build_start_stagger_seconds,
      min_free_memory_mb: settings.agent.min_free_memory_mb
    ]

    assert {:error, reason} = BuildGate.prepare_writable_root(gate_opts)
    assert Config.codex_runtime_settings(workspace) == {:error, reason}
  end

  defmodule ErrorContributor do
    def contribute(_policy, _settings, _opts), do: {:error, :contributor_failed}
  end

  defmodule RaisingContributor do
    def contribute(_policy, _settings, _opts), do: raise("contributor raised")
  end

  test "root order follows the registered contributors", %{workspace: workspace} do
    contributors = [BuildGate.SandboxRoots, Budget.SandboxRoots, AgentEnvironment.SandboxRoots]
    Application.put_env(:aiur, :turn_sandbox_root_contributors, contributors)
    assert {:ok, base} = Schema.resolve_runtime_turn_sandbox_policy(Config.settings!(), workspace)
    assert {:ok, settings} = Config.codex_runtime_settings(workspace)

    assert settings.turn_sandbox_policy["writableRoots"] ==
             base["writableRoots"] ++ [BuildGate.gate_dir(), Budget.state_dir()] ++ AgentEnvironment.package_cache_paths([])
  end

  test "empty or absent registry leaves the resolved policy unchanged", %{workspace: workspace} do
    assert {:ok, base} = Schema.resolve_runtime_turn_sandbox_policy(Config.settings!(), workspace)
    Application.put_env(:aiur, :turn_sandbox_root_contributors, [])
    assert {:ok, settings} = Config.codex_runtime_settings(workspace)
    assert settings.turn_sandbox_policy == base

    Application.delete_env(:aiur, :turn_sandbox_root_contributors)
    assert {:ok, settings} = Config.codex_runtime_settings(workspace)
    assert settings.turn_sandbox_policy == base
  end

  test "first contributor error stops the registry", %{workspace: workspace} do
    Application.put_env(:aiur, :turn_sandbox_root_contributors, [ErrorContributor, RaisingContributor])
    assert Config.codex_runtime_settings(workspace) == {:error, :contributor_failed}
  end

  test "contributor exceptions propagate", %{workspace: workspace} do
    Application.put_env(:aiur, :turn_sandbox_root_contributors, [RaisingContributor])
    assert_raise RuntimeError, "contributor raised", fn -> Config.codex_runtime_settings(workspace) end
  end
end
