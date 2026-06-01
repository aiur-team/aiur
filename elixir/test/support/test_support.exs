defmodule Aiur.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias Aiur.AgentRunner
      alias Aiur.CLI
      alias Aiur.Codex.CodingAgent, as: AppServer
      alias Aiur.Config
      alias Aiur.HttpServer
      alias Aiur.Issue
      alias Aiur.Linear.Client
      alias Aiur.Orchestrator
      alias Aiur.PromptBuilder
      alias Aiur.StatusDashboard
      alias Aiur.Tracker
      alias Aiur.Workflow
      alias Aiur.WorkflowStore
      alias Aiur.Workspace

      # Backend config aliases for tests
      alias Aiur.Codex.Config, as: CodexConfig
      alias Aiur.Linear.Config, as: LinearConfig

      import Aiur.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        workflow_base =
          Path.join(
            System.tmp_dir!(),
            "aiur-elixir-tests-#{System.get_env("USER") || System.get_env("LOGNAME") || "local"}"
          )

        workflow_root =
          Path.join(
            workflow_base,
            "workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, ".aiurconfig")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(Aiur.WorkflowStore), do: Aiur.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:aiur, :workflow_file_path)
          Application.delete_env(:aiur, :server_port_override)
          Application.delete_env(:aiur, :memory_tracker_issues)
          Application.delete_env(:aiur, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    {config_yaml, prompt} = workflow_content(overrides)

    config_yaml =
      if is_binary(prompt) and prompt != "" do
        prompt_basename = Path.basename(path) <> ".prompt.md"
        File.write!(Path.join(Path.dirname(path), prompt_basename), prompt <> "\n")
        config_yaml <> "prompt_file: #{prompt_basename}\n"
      else
        config_yaml
      end

    File.write!(path, config_yaml)

    if Process.whereis(Aiur.WorkflowStore) do
      try do
        Aiur.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    if is_nil(Process.whereis(Aiur.Supervisor)) do
      :ok
    else
      stop_default_http_server_child()
    end
  end

  defp stop_default_http_server_child do
    case Enum.find(Supervisor.which_children(Aiur.Supervisor), fn
           {Aiur.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {Aiur.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          tracker_repo: nil,
          tracker_label_prefix: nil,
          max_vertical_panes: 3,
          agent_kind: "codex",
          poll_interval_seconds: 30,
          workspace_root: Path.join(System.tmp_dir!(), "aiur_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          agent_turn_timeout_ms: 3_600_000,
          agent_read_timeout_ms: 5_000,
          agent_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          opencode_command: "opencode",
          opencode_bridge_port: 4097,
          opencode_bridge_host: "127.0.0.1",
          opencode_serve_args: [],
          opencode_model_prefix: "aiur",
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    agent_kind = Keyword.get(config, :agent_kind)
    max_vertical_panes = Keyword.get(config, :max_vertical_panes)
    poll_interval_seconds = Keyword.get(config, :poll_interval_seconds)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    agent_turn_timeout_ms = Keyword.get(config, :agent_turn_timeout_ms)
    agent_read_timeout_ms = Keyword.get(config, :agent_read_timeout_ms)
    agent_stall_timeout_ms = Keyword.get(config, :agent_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    opencode_command = Keyword.get(config, :opencode_command)
    opencode_bridge_port = Keyword.get(config, :opencode_bridge_port)
    opencode_bridge_host = Keyword.get(config, :opencode_bridge_host)
    opencode_serve_args = Keyword.get(config, :opencode_serve_args)
    opencode_model_prefix = Keyword.get(config, :opencode_model_prefix)
    prompt = Keyword.get(config, :prompt)

    config =
      if Keyword.has_key?(config, :codex_command) and not Keyword.has_key?(overrides, :command) do
        Keyword.put(config, :command, Keyword.get(config, :codex_command))
      else
        config
      end

    config =
      config
      |> maybe_copy_override(overrides, :codex_turn_timeout_ms, :agent_turn_timeout_ms)
      |> maybe_copy_override(overrides, :codex_read_timeout_ms, :agent_read_timeout_ms)
      |> maybe_copy_override(overrides, :codex_stall_timeout_ms, :agent_stall_timeout_ms)

    sections =
      [
        tracker_backend_yaml(tracker_kind, config),
        "max_vertical_panes: #{yaml_value(max_vertical_panes)}",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_seconds: #{yaml_value(poll_interval_seconds)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  kind: #{yaml_value(agent_kind)}",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "  turn_timeout_ms: #{yaml_value(agent_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(agent_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(agent_stall_timeout_ms)}",
        agent_backend_yaml(agent_kind, config),
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        opencode_yaml(
          opencode_command,
          opencode_bridge_port,
          opencode_bridge_host,
          opencode_serve_args,
          opencode_model_prefix
        )
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    {Enum.join(sections, "\n") <> "\n", prompt}
  end

  defp tracker_backend_yaml("linear", config) do
    endpoint = Keyword.get(config, :tracker_endpoint)
    api_token = Keyword.get(config, :tracker_api_token)
    project_slug = Keyword.get(config, :tracker_project_slug)
    assignee = Keyword.get(config, :tracker_assignee)

    [
      "linear:",
      "  endpoint: #{yaml_value(endpoint)}",
      "  api_key: #{yaml_value(api_token)}",
      "  project_slug: #{yaml_value(project_slug)}",
      "  assignee: #{yaml_value(assignee)}"
    ]
    |> Enum.join("\n")
  end

  defp tracker_backend_yaml("github", config) do
    repo = Keyword.get(config, :tracker_repo)
    label_prefix = Keyword.get(config, :tracker_label_prefix)
    bot_account = Keyword.get(config, :tracker_bot_account)

    [
      "github:",
      repo && "  repo: #{yaml_value(repo)}",
      label_prefix && "  label_prefix: #{yaml_value(label_prefix)}",
      bot_account && "  bot_account: #{yaml_value(bot_account)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp tracker_backend_yaml("memory", _config), do: "memory: {}"
  defp tracker_backend_yaml(nil, _config), do: nil
  defp tracker_backend_yaml(_kind, _config), do: nil

  defp opencode_yaml(command, bridge_port, bridge_host, serve_args, model_prefix) do
    [
      "opencode:",
      "  command: #{yaml_value(command)}",
      "  bridge_port: #{yaml_value(bridge_port)}",
      "  bridge_host: #{yaml_value(bridge_host)}",
      "  serve_args: #{yaml_value(serve_args)}",
      "  model_prefix: #{yaml_value(model_prefix)}"
    ]
    |> Enum.join("\n")
  end

  defp agent_backend_yaml("codex", config) do
    command = Keyword.get(config, :command)
    approval_policy = Keyword.get(config, :codex_approval_policy)
    thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    turn_timeout_ms = Keyword.get(config, :agent_turn_timeout_ms)
    read_timeout_ms = Keyword.get(config, :agent_read_timeout_ms)
    stall_timeout_ms = Keyword.get(config, :agent_stall_timeout_ms)

    [
      "codex:",
      "  command: #{yaml_value(command)}",
      "  approval_policy: #{yaml_value(approval_policy)}",
      "  thread_sandbox: #{yaml_value(thread_sandbox)}",
      "  turn_sandbox_policy: #{yaml_value(turn_sandbox_policy)}",
      "  turn_timeout_ms: #{yaml_value(turn_timeout_ms)}",
      "  read_timeout_ms: #{yaml_value(read_timeout_ms)}",
      "  stall_timeout_ms: #{yaml_value(stall_timeout_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp agent_backend_yaml("claude", config) do
    command = Keyword.get(config, :command)
    model = Keyword.get(config, :claude_model)
    version = Keyword.get(config, :claude_version)
    permission_mode = Keyword.get(config, :claude_permission_mode)

    [
      "claude:",
      "  command: #{yaml_value(command)}",
      model && "  model: #{yaml_value(model)}",
      version && "  version: #{yaml_value(version)}",
      permission_mode && "  permission_mode: #{yaml_value(permission_mode)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp agent_backend_yaml(nil, _config), do: nil
  defp agent_backend_yaml(_kind, _config), do: nil

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp maybe_copy_override(config, overrides, from_key, to_key) do
    if Keyword.has_key?(overrides, from_key) and not Keyword.has_key?(overrides, to_key) do
      Keyword.put(config, to_key, Keyword.get(overrides, from_key))
    else
      config
    end
  end

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
