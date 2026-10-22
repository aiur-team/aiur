defmodule Aiur.TestSupport.WorkflowYaml do
  import Aiur.TestSupport.WorkflowYaml.Sections
  @workflow_prompt "You are an agent for this repository."

  def workflow_content(overrides) do
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
          tracker_bot_account: nil,
          # Left nil so the default fixture renders no `identity_mode` key at
          # all, exercising the schema default an existing install is on.
          tracker_identity_mode: nil,
          tracker_github_app_account: nil,
          tracker_trusted_accounts: [],
          tracker_planning_root_limit: 100,
          tracker_planning_page_budget: 4,
          tracker_planning_call_budget: 4,
          tracker_base_branch: "main",
          max_vertical_panes: 3,
          pre_warmed_sessions: 3,
          agent_kind: "codex",
          agent_routing: %{},
          poll_interval_seconds: 30,
          workspace_root: Path.join(System.tmp_dir!(), "aiur_workspaces"),
          workspace_bootstrap_image: nil,
          workspace_bootstrap_image_pull: false,
          workspace_wip: [],
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_concurrent_builds: 4,
          build_start_stagger_seconds: 0,
          min_free_memory_mb: nil,
          max_turns: 20,
          max_dispatches_per_ticket: nil,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          command: "codex app-server",
          codex_approval_policy: "untrusted",
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
    tracker_base_branch = Keyword.get(config, :tracker_base_branch)
    tracker_terminal_fence_grace_seconds = Keyword.get(config, :tracker_terminal_fence_grace_seconds)
    agent_kind = Keyword.get(config, :agent_kind)
    agent_routing = Keyword.get(config, :agent_routing)
    max_vertical_panes = Keyword.get(config, :max_vertical_panes)
    pre_warmed_sessions = Keyword.get(config, :pre_warmed_sessions)
    poll_interval_seconds = Keyword.get(config, :poll_interval_seconds)
    workspace_root = Keyword.get(config, :workspace_root)
    workspace_bootstrap_image = Keyword.get(config, :workspace_bootstrap_image)
    workspace_bootstrap_image_pull = Keyword.get(config, :workspace_bootstrap_image_pull)
    workspace_wip = Keyword.get(config, :workspace_wip, [])
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)

    worker_max_concurrent_agents_per_host =
      Keyword.get(config, :worker_max_concurrent_agents_per_host)

    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_concurrent_builds = Keyword.get(config, :max_concurrent_builds)
    build_start_stagger_seconds = Keyword.get(config, :build_start_stagger_seconds)
    min_free_memory_mb = Keyword.get(config, :min_free_memory_mb)
    max_turns = Keyword.get(config, :max_turns)
    max_dispatches_per_ticket = Keyword.get(config, :max_dispatches_per_ticket)
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
    observability_writable = Keyword.get(config, :observability_writable)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    observability_retention_max_bytes = Keyword.get(config, :observability_retention_max_bytes)
    observability_retention_max_age_days = Keyword.get(config, :observability_retention_max_age_days)
    observability_retention_prune_interval_bytes = Keyword.get(config, :observability_retention_prune_interval_bytes)
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

    _ = {agent_turn_timeout_ms, agent_read_timeout_ms, agent_stall_timeout_ms}

    tracker_section =
      [
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "  base_branch: #{yaml_value(tracker_base_branch)}",
        tracker_terminal_fence_grace_seconds &&
          "  terminal_fence_grace_seconds: #{yaml_value(tracker_terminal_fence_grace_seconds)}",
        tracker_github_yaml(tracker_kind, config),
        tracker_linear_yaml(tracker_kind, config)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    agent_section =
      [
        "agent:",
        "  kind: #{yaml_value(agent_kind)}",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_concurrent_builds: #{yaml_value(max_concurrent_builds)}",
        "  build_start_stagger_seconds: #{yaml_value(build_start_stagger_seconds)}",
        "  min_free_memory_mb: #{yaml_value(min_free_memory_mb)}",
        "  max_turns: #{yaml_value(max_turns)}",
        max_dispatches_per_ticket &&
          "  max_dispatches_per_ticket: #{yaml_value(max_dispatches_per_ticket)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "  routing: #{yaml_value(agent_routing)}",
        "  turn_timeout_ms: #{yaml_value(Keyword.get(config, :agent_turn_timeout_ms))}",
        "  stall_timeout_ms: #{yaml_value(Keyword.get(config, :agent_stall_timeout_ms))}",
        agent_backend_yaml(agent_kind, config)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    sections =
      [
        "max_vertical_panes: #{yaml_value(max_vertical_panes)}",
        "pre_warmed_sessions: #{yaml_value(pre_warmed_sessions)}",
        tracker_section,
        "polling:",
        "  interval_seconds: #{yaml_value(poll_interval_seconds)}",
        polling_intervals_yaml(config),
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        workspace_bootstrap_image && "  bootstrap_image: #{yaml_value(workspace_bootstrap_image)}",
        "  bootstrap_image_pull: #{yaml_value(workspace_bootstrap_image_pull)}",
        Enum.map_join(workspace_wip, "\n", fn {key, value} -> "  wip_#{key}: #{yaml_value(value)}" end),
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        agent_section,
        hooks_yaml(
          hook_after_create,
          hook_before_run,
          hook_after_run,
          hook_before_remove,
          hook_timeout_ms
        ),
        observability_yaml(
          observability_enabled,
          observability_writable,
          observability_refresh_ms,
          observability_render_interval_ms,
          observability_retention_max_bytes,
          observability_retention_max_age_days,
          observability_retention_prune_interval_bytes
        ),
        decisions_yaml(overrides),
        server_yaml(server_port, server_host),
        opencode_yaml(
          opencode_command,
          opencode_bridge_port,
          opencode_bridge_host,
          opencode_serve_args,
          opencode_model_prefix
        ),
        alerts_yaml(overrides),
        pr_watch_yaml(overrides),
        pr_health_yaml(overrides)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    {Enum.join(sections, "\n") <> "\n", prompt}
  end

  defp tracker_linear_yaml("linear", config) do
    endpoint = Keyword.get(config, :tracker_endpoint)
    api_token = Keyword.get(config, :tracker_api_token)
    project_slug = Keyword.get(config, :tracker_project_slug)
    assignee = Keyword.get(config, :tracker_assignee)

    [
      "  linear:",
      "    endpoint: #{yaml_value(endpoint)}",
      "    api_key: #{yaml_value(api_token)}",
      "    project_slug: #{yaml_value(project_slug)}",
      "    assignee: #{yaml_value(assignee)}"
    ]
    |> Enum.join("\n")
  end

  defp tracker_linear_yaml(_kind, _config), do: nil

  # A key that only means anything under a GitHub tracker: nil for any other
  # kind, so the caller renders no line for it at all.
  defp github_only("github", config, key), do: Keyword.get(config, key)
  defp github_only(_kind, _config, _key), do: nil

  defp tracker_github_yaml(tracker_kind, config) do
    repo = github_only(tracker_kind, config, :tracker_repo)
    label_prefix = github_only(tracker_kind, config, :tracker_label_prefix)
    bot_account = github_only(tracker_kind, config, :tracker_bot_account)
    identity_mode = github_only(tracker_kind, config, :tracker_identity_mode)
    trusted_accounts = if tracker_kind == "github", do: Keyword.get(config, :tracker_trusted_accounts, []), else: []
    root_limit = Keyword.fetch!(config, :tracker_planning_root_limit)
    page_budget = Keyword.fetch!(config, :tracker_planning_page_budget)
    call_budget = Keyword.fetch!(config, :tracker_planning_call_budget)

    [
      "  github:",
      repo && "    repo: #{yaml_value(repo)}",
      label_prefix && "    label_prefix: #{yaml_value(label_prefix)}",
      bot_account && "    bot_account: #{yaml_value(bot_account)}",
      identity_mode && "    identity_mode: #{yaml_value(identity_mode)}",
      tracker_github_app_yaml(tracker_kind, config),
      trusted_accounts != [] && "    trusted_accounts: #{yaml_value(trusted_accounts)}",
      "    planning_root_limit: #{yaml_value(root_limit)}",
      "    planning_page_budget: #{yaml_value(page_budget)}",
      "    planning_call_budget: #{yaml_value(call_budget)}"
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join("\n")
  end

  # Rendered only when a case asks for it, so the default fixture exercises the
  # optional-block path an install without a GitHub App is on.
  defp tracker_github_app_yaml("github", config) do
    case Keyword.get(config, :tracker_github_app_account) do
      nil -> nil
      account -> "    github_app:\n      account: #{yaml_value(account)}"
    end
  end

  defp tracker_github_app_yaml(_kind, _config), do: nil

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
    read_timeout_ms = Keyword.get(config, :agent_read_timeout_ms)
    reset_time_zone = Keyword.get(config, :codex_reset_time_zone)

    [
      "  codex:",
      "    command: #{yaml_value(command)}",
      "    approval_policy: #{yaml_value(approval_policy)}",
      "    thread_sandbox: #{yaml_value(thread_sandbox)}",
      "    turn_sandbox_policy: #{yaml_value(turn_sandbox_policy)}",
      "    read_timeout_ms: #{yaml_value(read_timeout_ms)}",
      reset_time_zone && "    reset_time_zone: #{yaml_value(reset_time_zone)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp agent_backend_yaml("claude", config) do
    command = Keyword.get(config, :command)
    model = Keyword.get(config, :claude_model)
    permission_mode = Keyword.get(config, :claude_permission_mode)

    [
      "  claude:",
      "    command: #{yaml_value(command)}",
      model && "    model: #{yaml_value(model)}",
      permission_mode && "    permission_mode: #{yaml_value(permission_mode)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp agent_backend_yaml(nil, _config), do: nil
  defp agent_backend_yaml(_kind, _config), do: nil

  defp maybe_copy_override(config, overrides, from_key, to_key) do
    if Keyword.has_key?(overrides, from_key) and not Keyword.has_key?(overrides, to_key) do
      Keyword.put(config, to_key, Keyword.get(overrides, from_key))
    else
      config
    end
  end
end
