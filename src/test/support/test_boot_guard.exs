defmodule Aiur.TestBootGuard do
  @moduledoc false

  alias Aiur.Config.Paths
  alias Aiur.Executor.StatePaths
  alias Aiur.GitHub.Budget
  alias Aiur.Upgrade.State

  def check! do
    original_home = Application.fetch_env!(:aiur, :test_original_home)
    root = Application.fetch_env!(:aiur, :test_state_root)
    {:ok, decisions} = Paths.decision_state_dir()

    paths = [
      budget: Budget.state_dir(),
      decisions: decisions,
      workspace: Aiur.Config.workspace_root(),
      logs: Paths.log_root_dir(),
      executor: StatePaths.dir(),
      repo: Application.fetch_env!(:aiur, :repo_base_root),
      build_gate: Aiur.BuildGate.gate_dir(),
      host_guard: Aiur.AgentGitHubGuard.host_bin_dir(),
      home: System.fetch_env!("HOME"),
      upgrade: State.path()
    ]

    env_paths =
      for name <- ~w(AIUR_BG_STATE_DIR XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME
                      XDG_RUNTIME_DIR CODEX_HOME GH_CONFIG_DIR AIUR_WORKSPACE_ROOT_FILE
                      AIUR_ALERT_LEDGER_PATH_FILE AIUR_SESSION_TMPFILE AIUR_AGENT_TMPFILE),
          path = System.get_env(name),
          is_binary(path),
          do: {name, path}

    derived_paths =
      for resolver <- [
            :current_run_membership_state_dir,
            :progress_retention_state_dir,
            :usage_ledger_state_dir,
            :usage_aggregate_state_dir,
            :usage_compaction_state_dir,
            :takeover_alert_state_dir,
            :balance_baseline_state_dir
          ] do
        {:ok, path} = apply(Paths, resolver, [])
        {resolver, path}
      end

    assert_safe!(paths ++ env_paths ++ derived_paths, original_home)

    # HOME isolation is a second barrier, not a replacement for explicit state
    # configuration. Removing a boot directory override must fail the suite.
    for key <- [:github_budget_dir, :decision_state_dir, :executor_state_dir] do
      path = Application.get_env(:aiur, key)
      unless is_binary(path) and contained?(root, path), do: unsafe!(key, path)
    end

    :ok
  end

  def assert_safe!(paths, original_home) do
    protected = [Path.join(original_home, ".aiur"), Path.join(original_home, ".config/aiur")]

    for {name, path} <- paths do
      if Enum.any?(protected, &contained?(&1, path)), do: unsafe!(name, path)
    end

    :ok
  end

  defp contained?(root, path) do
    case Aiur.PathSafety.contained?(root, path) do
      {:ok, _} -> true
      {:error, :outside_root} -> false
      {:error, reason} -> raise "TEST BOOT ISOLATION: cannot check #{inspect(path)}: #{inspect(reason)}"
    end
  end

  defp unsafe!(name, path) do
    raise "TEST BOOT ISOLATION: unsafe #{name}=#{inspect(path)}; isolate state in config/config.exs before app boot"
  end
end
