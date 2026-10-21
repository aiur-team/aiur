defmodule Aiur.GitHub.AccessSettingsTest do
  use Aiur.TestSupport

  alias Aiur.Config.Paths
  alias Aiur.GitHub.{AccessSettings, Budget, CredentialRegistry, RequestLog}
  alias Aiur.GitHub.ReadCache.Policy, as: CachePolicy
  alias Aiur.GitHub.Quota.{ShellObservations, Windows}
  alias Aiur.GitHub.ResourceStore.Persistence
  alias Aiur.TestSupport.WorkflowFiles
  alias Aiur.{Workflow, WorkflowStore}

  @tag :tmp_dir
  test "characterizes existing paths and settings for future refactors", %{tmp_dir: root} do
    for key <- [:repo_base_root, :decision_state_dir, :github_budget_dir] do
      previous = Application.fetch_env(:aiur, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:aiur, key, value)
          :error -> Application.delete_env(:aiur, key)
        end
      end)
    end

    Application.put_env(:aiur, :repo_base_root, Path.join(root, "repo"))
    Application.put_env(:aiur, :decision_state_dir, Path.join(root, "decisions"))
    Application.put_env(:aiur, :github_budget_dir, Path.join(root, "budget"))
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "o/r", workspace_root: Path.join(root, "workspaces"))

    assert Budget.state_dir() == Path.join(root, "budget")
    assert Budget.database_path() == Path.join(root, "budget/budget.sqlite3")
    assert Windows.default_hold_dir() == Path.join(root, "repo/o/r/github-quota")
    assert RequestLog.default_path() == nil
    assert Persistence.resolve_path([]) == Path.join(root, "decisions/github_resources.json")
    assert ShellObservations.default_shell_log_path() == Path.join(root, "workspaces/o/r/*/.aiur-runtime/github-quota/agent-requests.tsv")
    assert [%{id: "primary", primary?: true}] = CredentialRegistry.configured()
    assert Budget.guard_settings().daemon_core_limit_per_hour == 3000
    refute Budget.enabled?()
    original_env = Application.get_env(:aiur, :env)
    Application.put_env(:aiur, :env, :dev)

    try do
      assert RequestLog.default_path() == Path.join(root, "repo/o/r/github-quota/daemon-requests.tsv")
    after
      Application.put_env(:aiur, :env, original_env)
    end
  end

  test "configured credential order and scalar fields cross the provider boundary" do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "github", tracker_repo: "o/r", tracker_bot_account: "agent")

    credentials = """
        credentials:
          - id: first
            kind: machine_user
            token_env: FIRST_TOKEN
            writes: true
          - id: second
            kind: human
            token_env: SECOND_TOKEN
          - id: disabled
            kind: machine_user
            token_env: DISABLED_TOKEN
            enabled: false
    """

    yaml = File.read!(path) |> String.replace("    planning_root_limit:", credentials <> "    planning_root_limit:")
    WorkflowFiles.write_workflow_file_atomic!(path, yaml)
    assert :ok = WorkflowStore.force_reload()
    assert [primary, first, second] = CredentialRegistry.configured()
    assert {primary.id, primary.identity, primary.primary?} == {"primary", "agent", true}
    assert {first.id, first.kind, first.writes?, first.token_env} == {"first", :machine_user, true, "FIRST_TOKEN"}
    assert {second.id, second.kind, second.writes?, second.token_env} == {"second", :human, false, "SECOND_TOKEN"}
    settings = AccessSettings.settings()
    assert settings.repo == "o/r"
    refute is_struct(settings.budget)
    assert settings.budget.daemon_core_limit_per_hour == 3000
  end

  test "the next budget call sees a reloaded workflow limit" do
    path = Workflow.workflow_file_path()
    original = File.read!(path)

    on_exit(fn ->
      File.write!(path, original)
      WorkflowStore.force_reload()
    end)

    for limit <- [17, 23] do
      write_workflow_file!(path, tracker_kind: "github", tracker_repo: "o/r")
      yaml = File.read!(path) |> String.replace("    planning_root_limit:", "    daemon_core_limit_per_hour: #{limit}\n    planning_root_limit:")
      WorkflowFiles.write_workflow_file_atomic!(path, yaml)
      assert :ok = WorkflowStore.force_reload()
      assert Budget.guard_settings().daemon_core_limit_per_hour == limit
    end
  end

  test "scalar cache and budget reads do not resolve durable filesystem paths" do
    parent = self()
    paths_call = {Paths, :decision_state_dir, 0}
    Code.ensure_loaded!(Paths)
    :erlang.trace_pattern(paths_call, true, [:local])

    worker =
      spawn(fn ->
        receive do
          :read ->
            CachePolicy.ttl_ms(:issue)
            send(parent, {:read_done, self(), Budget.guard_settings()})

            receive do
              :stop -> :ok
            end
        end
      end)

    on_exit(fn ->
      :erlang.trace_pattern(paths_call, false, [:local])
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    :erlang.trace(worker, true, [:call, {:tracer, self()}])
    send(worker, :read)
    receive_barrier({:read_done, ^worker, settings})
    barrier = :erlang.trace_delivered(worker)
    receive_barrier({:trace_delivered, ^worker, ^barrier})
    assert settings.daemon_core_limit_per_hour == 3000
    refute_received {:trace, ^worker, :call, {Paths, :decision_state_dir, []}}
    send(worker, :stop)
  end
end
