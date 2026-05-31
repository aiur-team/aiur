defmodule Aiur.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias Aiur.Config.Schema
  alias Aiur.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        config
        |> prepare_config()
        |> Schema.parse()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec section(String.t()) :: map()
  def section(name) when is_binary(name) do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Map.get(config, name) || Map.get(config, String.to_atom(name)) || %{}

      _ ->
        %{}
    end
  end

  @spec tracker_kind() :: String.t() | nil
  def tracker_kind do
    settings!().tracker.kind
  end

  @spec agent_kind() :: String.t()
  def agent_kind do
    settings!().agent.kind || "codex"
  end

  @spec agent_routing() :: %{pos_integer() => String.t()}
  def agent_routing do
    settings!().agent.routing || %{}
  end

  @spec active_states() :: [String.t()]
  def active_states do
    settings!().tracker.active_states
  end

  @spec terminal_states() :: [String.t()]
  def terminal_states do
    settings!().tracker.terminal_states
  end

  @spec poll_interval_seconds() :: pos_integer()
  def poll_interval_seconds do
    settings!().polling.interval_seconds
  end

  @spec events_block_state_debounce_seconds() :: non_neg_integer()
  def events_block_state_debounce_seconds do
    settings!().events.block_state_debounce_seconds
  end

  @spec events_custom_events_per_turn_max() :: pos_integer()
  def events_custom_events_per_turn_max do
    settings!().events.custom_events_per_turn_max
  end

  @spec events_codeowners_refresh_seconds() :: pos_integer()
  def events_codeowners_refresh_seconds do
    settings!().events.codeowners_refresh_seconds
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    settings!().workspace.root
  end

  @spec max_vertical_panes() :: pos_integer()
  def max_vertical_panes do
    settings!().max_vertical_panes
  end

  @spec workspace_hooks() :: map()
  def workspace_hooks do
    hooks = settings!().hooks

    %{
      after_create: hooks.after_create,
      before_run: hooks.before_run,
      after_run: hooks.after_run,
      before_remove: hooks.before_remove,
      timeout_ms: hooks.timeout_ms
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    settings!().hooks.timeout_ms
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    settings!().agent.max_concurrent_agents
  end

  @doc """
  Number of opencode-serve instances to pre-warm at boot. Each pre-
  warmed slot binds to a different active ticket as its leadoff so
  the user's first click on that ticket opens its chat pane in
  <100 ms. Defaults to 3 when absent from WORKFLOW. `0` is valid
  and disables pre-warm entirely (all opens go through the cold
  placeholder path).
  """
  @spec pre_warmed_sessions() :: non_neg_integer()
  def pre_warmed_sessions do
    settings!().pre_warmed_sessions
  end

  @spec max_retry_attempts() :: pos_integer()
  def max_retry_attempts do
    settings!().agent.max_retry_attempts
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    settings!().agent.max_retry_backoff_ms
  end

  @spec codex_thrash_max_per_window() :: pos_integer()
  def codex_thrash_max_per_window do
    settings!().agent.codex_thrash_max_per_window
  end

  @spec codex_thrash_window_seconds() :: pos_integer()
  def codex_thrash_window_seconds do
    settings!().agent.codex_thrash_window_seconds
  end

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns do
    settings!().agent.max_turns
  end

  @spec agent_turn_timeout_ms() :: pos_integer()
  def agent_turn_timeout_ms do
    settings!().codex.turn_timeout_ms
  end

  @spec agent_read_timeout_ms() :: pos_integer()
  def agent_read_timeout_ms do
    settings!().codex.read_timeout_ms
  end

  @spec agent_stall_timeout_ms() :: non_neg_integer()
  def agent_stall_timeout_ms do
    settings!().codex.stall_timeout_ms
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:aiur, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    case Application.get_env(:aiur, :server_host_override) do
      host when is_binary(host) and host != "" -> host
      _ -> settings!().server.host
    end
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    settings!().observability.dashboard_enabled
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    settings!().observability.refresh_ms
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    settings!().observability.render_interval_ms
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    with :ok <- validate_kinds_and_secrets(settings) do
      Aiur.Opencode.Config.validate!()
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_kinds_and_secrets(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "github", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.agent.kind not in Aiur.CodingAgent.known_backends() ->
        {:error, {:unsupported_agent_kind, settings.agent.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      settings.tracker.kind == "github" ->
        Aiur.GitHub.Config.validate!()

      settings.agent.kind == "claude" ->
        Aiur.Claude.Config.validate!()

      true ->
        :ok
    end
  end

  defp prepare_config(config) do
    tracker = map_section(config, "tracker")
    agent = map_section(config, "agent")
    linear = map_section(config, "linear")

    config
    |> Map.put("tracker", prepare_tracker_config(config, tracker, linear))
    |> Map.put("agent", prepare_agent_config(config, agent))
  end

  defp prepare_tracker_config(config, tracker, linear) do
    tracker
    |> Map.merge(linear, fn _key, tracker_value, _linear_value -> tracker_value end)
    |> put_default_kind(inferred_tracker_kind(config))
  end

  defp prepare_agent_config(config, agent) do
    put_default_kind(agent, inferred_agent_kind(config))
  end

  defp put_default_kind(section, kind) do
    case Map.get(section, "kind") || Map.get(section, :kind) do
      nil -> Map.put(section, "kind", kind)
      _ -> section
    end
  end

  defp inferred_tracker_kind(config) do
    cond do
      has_section?(config, "github") -> "github"
      has_section?(config, "linear") -> "linear"
      has_section?(config, "memory") -> "memory"
      true -> nil
    end
  end

  defp inferred_agent_kind(config) do
    cond do
      has_section?(config, "claude") -> "claude"
      has_section?(config, "codex") -> "codex"
      true -> "claude"
    end
  end

  defp has_section?(config, name) do
    Map.has_key?(config, name) or Map.has_key?(config, String.to_atom(name))
  end

  defp map_section(config, name) do
    case Map.get(config, name) || Map.get(config, String.to_atom(name)) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp format_config_error(reason) do
    label = config_file_label()

    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid #{label} config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing #{Path.basename(path)} at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse #{label}: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse #{label}: workflow front matter must decode to a map"

      other ->
        "Invalid #{label} config: #{inspect(other)}"
    end
  end

  defp config_file_label do
    Path.basename(Workflow.workflow_file_path())
  end
end
