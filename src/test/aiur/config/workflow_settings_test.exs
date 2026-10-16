defmodule Aiur.Config.WorkflowSettingsTest do
  use Aiur.TestSupport
  import Aiur.TestSupport.RejectedWorkflow
  alias Aiur.Config.Schema.{AgentValidation, Codex, StringOrMap}
  alias Ecto.Changeset

  test "observability.dashboard_writable re-enables dashboard writes" do
    write_workflow_file!(Workflow.workflow_file_path(), observability_writable: true)

    assert :ok = Config.validate!()
    assert Config.settings!().observability.dashboard_writable == true
    assert Config.dashboard_writable?()
  end

  test "telemetry retention derives and accepts its prune interval" do
    write_workflow_file!(Workflow.workflow_file_path(), observability_retention_max_bytes: 8 * 1024 * 1024)

    assert Config.telemetry_retention() == [
             max_bytes: 8 * 1024 * 1024,
             max_age_days: 30,
             prune_interval_bytes: 1 * 1024 * 1024
           ]

    write_workflow_file!(Workflow.workflow_file_path(),
      observability_retention_max_bytes: 8 * 1024 * 1024,
      observability_retention_prune_interval_bytes: 256
    )

    assert Config.telemetry_retention() == [
             max_bytes: 8 * 1024 * 1024,
             max_age_days: 30,
             prune_interval_bytes: 256
           ]
  end

  test "decision supervisor policy round-trips through workflow configuration" do
    write_workflow_file!(Workflow.workflow_file_path(),
      supervisor_decision_allowed_kinds: [" Architecture ", "PRODUCT", "architecture"],
      supervisor_decision_allow_non_reversible: true
    )

    assert :ok = Config.validate!()

    assert Config.supervisor_decision_policy() == %{
             allowed_kinds: ["architecture", "product"],
             allow_non_reversible: true
           }
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.linear.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.linear.api_key == nil
    assert config.tracker.linear.project_slug == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "aiur_workspaces")
    assert config.workspace.bootstrap_image == nil
    refute config.workspace.bootstrap_image_pull
    assert config.worker.max_concurrent_agents_per_host == nil
    # `max_concurrent_agents` is nil at the schema level; the derived default
    # (calibrated from host schedulers) is resolved by `Config.max_concurrent_agents/0`.
    assert config.agent.max_concurrent_agents == nil
    assert Config.max_concurrent_agents() == Config.default_max_concurrent_agents()

    # Dashboard binds a free loopback port by default so claude remote-control's
    # transcript hook works without explicit server config. Port 0 = OS-assigned;
    # HttpServer.bound_port/0 reports the real port.
    assert config.server.port == 0

    # Dashboard writes are enabled by default for authenticated operators.
    assert config.observability.dashboard_writable == true
    assert Config.dashboard_writable?()

    assert Config.supervisor_decision_policy() == %{
             allowed_kinds: [],
             allow_non_reversible: false
           }

    assert config.agent.codex.command == "codex app-server"

    assert config.agent.codex.approval_policy == "untrusted"

    assert config.agent.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             Aiur.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "aiur_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => true
           }

    assert config.agent.turn_timeout_ms == 3_600_000
    assert config.agent.codex.read_timeout_ms == 5_000
    assert config.agent.stall_timeout_ms == 3_600_000

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.settings!().agent.codex.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    explicit_root = Aiur.TestSupport.tmp_root!("aiur-elixir-explicit-sandbox-root")

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)
    assert {:ok, canonical_explicit_workspace} = Aiur.PathSafety.canonicalize(explicit_workspace)

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.agent.codex.approval_policy == "on-request"
    assert config.agent.codex.thread_sandbox == "workspace-write"

    expected_explicit_roots =
      append_unique([explicit_workspace, explicit_cache], canonical_explicit_workspace)

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => expected_explicit_roots
           }

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert message =~ "tracker.active_states"

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert message =~ "agent.max_concurrent_agents"

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert message =~ "worker.max_concurrent_agents_per_host"

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert message =~ "agent.turn_timeout_ms"

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert message =~ "read_timeout_ms"

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert message =~ "agent.stall_timeout_ms"

    assert {:error, {:invalid_workflow_config, _message}} =
             write_rejected_workflow_file!(Workflow.workflow_file_path(),
               tracker_active_states: %{todo: true},
               tracker_terminal_states: %{done: true},
               poll_interval_seconds: %{bad: true},
               workspace_root: 123,
               max_retry_backoff_ms: 0,
               max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
               hook_timeout_ms: 0,
               observability_enabled: "maybe",
               observability_refresh_ms: %{bad: true},
               observability_render_interval_ms: %{bad: true},
               server_port: -1,
               server_host: 123
             )

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().agent.codex.approval_policy == ""
    assert {:error, {:invalid_codex_approval_policy, ""}} = Config.codex_runtime_settings()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().agent.codex.thread_sandbox == ""

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), workspace_bootstrap_image: "")
    assert message =~ "workspace.bootstrap_image"

    assert {:error, {:invalid_workflow_config, message}} = write_rejected_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.agent.codex.approval_policy == "future-policy"
    assert config.agent.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert {:error, {:invalid_codex_approval_policy, "future-policy"}} =
             Config.codex_runtime_settings()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().agent.codex.command == "codex app-server"
  end

  test "launcher dashboard default fills only a missing server host" do
    env_var = "AIUR_DEFAULT_DASHBOARD_HOST"
    previous_default = System.get_env(env_var)

    on_exit(fn -> restore_env(env_var, previous_default) end)
    System.delete_env(env_var)

    write_workflow_file!(Workflow.workflow_file_path())
    assert Config.settings!().server.host == "127.0.0.1"

    System.put_env(env_var, "100.64.0.10")

    write_workflow_file!(Workflow.workflow_file_path())
    assert Config.settings!().server.host == "100.64.0.10"

    write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0")
    assert Config.settings!().server.host == "0.0.0.0"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "aiur-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.linear.api_key == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.agent.codex.command == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "aiur-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.linear.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    config = """
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    """

    File.write!(Workflow.workflow_file_path(), config)
    # A raw write bypasses `write_workflow_file!/2`, which normally reloads the
    # store for you. Since #1731 a read no longer reloads on the caller's
    # behalf — the store owns freshness — so ask for the reload explicitly
    # rather than racing its one-second poll.
    assert :ok = WorkflowStore.force_reload()

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert AgentValidation.normalize_state_limits(nil) == %{}

    assert AgentValidation.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> AgentValidation.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  defp append_unique(values, value) do
    if value in values, do: values, else: values ++ [value]
  end
end
