defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias NimbleOptions
  alias SymphonyElixir.Workflow

  @default_active_states ["Todo", "In Progress"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @default_poll_interval_ms 30_000
  @default_workspace_root Path.join(System.tmp_dir!(), "symphony_workspaces")
  @default_hook_timeout_ms 60_000
  @default_max_concurrent_agents 10
  @default_agent_max_turns 20
  @default_max_retry_backoff_ms 300_000
  @default_agent_turn_timeout_ms 3_600_000
  @default_agent_read_timeout_ms 5_000
  @default_agent_stall_timeout_ms 300_000
  @default_observability_enabled true
  @default_observability_refresh_ms 1_000
  @default_observability_render_interval_ms 16
  @default_server_host "127.0.0.1"

  @tracker_sections ["linear", "github", "memory"]
  @agent_sections ["claude", "codex"]

  @workflow_options_schema NimbleOptions.new!(
                             tracker: [
                               type: :map,
                               default: %{},
                               keys: [
                                 active_states: [
                                   type: {:list, :string},
                                   default: @default_active_states
                                 ],
                                 terminal_states: [
                                   type: {:list, :string},
                                   default: @default_terminal_states
                                 ]
                               ]
                             ],
                             polling: [
                               type: :map,
                               default: %{},
                               keys: [
                                 interval_ms: [type: :integer, default: @default_poll_interval_ms]
                               ]
                             ],
                             workspace: [
                               type: :map,
                               default: %{},
                               keys: [
                                 root: [type: {:or, [:string, nil]}, default: @default_workspace_root]
                               ]
                             ],
                             agent: [
                               type: :map,
                               default: %{},
                               keys: [
                                 max_concurrent_agents: [
                                   type: :integer,
                                   default: @default_max_concurrent_agents
                                 ],
                                 max_turns: [
                                   type: :pos_integer,
                                   default: @default_agent_max_turns
                                 ],
                                 max_retry_backoff_ms: [
                                   type: :pos_integer,
                                   default: @default_max_retry_backoff_ms
                                 ],
                                 max_concurrent_agents_by_state: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ],
                                 turn_timeout_ms: [
                                   type: :integer,
                                   default: @default_agent_turn_timeout_ms
                                 ],
                                 read_timeout_ms: [
                                   type: :integer,
                                   default: @default_agent_read_timeout_ms
                                 ],
                                 stall_timeout_ms: [
                                   type: :integer,
                                   default: @default_agent_stall_timeout_ms
                                 ]
                               ]
                             ],
                             hooks: [
                               type: :map,
                               default: %{},
                               keys: [
                                 after_create: [type: {:or, [:string, nil]}, default: nil],
                                 before_run: [type: {:or, [:string, nil]}, default: nil],
                                 after_run: [type: {:or, [:string, nil]}, default: nil],
                                 before_remove: [type: {:or, [:string, nil]}, default: nil],
                                 timeout_ms: [type: :pos_integer, default: @default_hook_timeout_ms]
                               ]
                             ],
                             observability: [
                               type: :map,
                               default: %{},
                               keys: [
                                 dashboard_enabled: [
                                   type: :boolean,
                                   default: @default_observability_enabled
                                 ],
                                 refresh_ms: [
                                   type: :integer,
                                   default: @default_observability_refresh_ms
                                 ],
                                 render_interval_ms: [
                                   type: :integer,
                                   default: @default_observability_render_interval_ms
                                 ]
                               ]
                             ],
                             server: [
                               type: :map,
                               default: %{},
                               keys: [
                                 port: [type: {:or, [:non_neg_integer, nil]}, default: nil],
                                 host: [type: :string, default: @default_server_host]
                               ]
                             ]
                           )

  @type workflow_payload :: Workflow.loaded_workflow()
  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow do
    Workflow.current()
  end

  @spec section(String.t()) :: map()
  def section(name) when is_binary(name) do
    section_map(workflow_config(), name)
  end

  @spec tracker_kind() :: String.t()
  def tracker_kind do
    case detect_sections(@tracker_sections) do
      [] -> "github"
      [kind | _] -> kind
    end
  end

  @spec active_states() :: [String.t()]
  def active_states do
    get_in(validated_workflow_options(), [:tracker, :active_states])
  end

  @spec terminal_states() :: [String.t()]
  def terminal_states do
    get_in(validated_workflow_options(), [:tracker, :terminal_states])
  end

  @spec agent_kind() :: String.t()
  def agent_kind do
    case detect_sections(@agent_sections) do
      [] -> "claude"
      [kind | _] -> kind
    end
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    get_in(validated_workflow_options(), [:polling, :interval_ms])
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    validated_workflow_options()
    |> get_in([:workspace, :root])
    |> resolve_path_value(@default_workspace_root)
  end

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    hooks = get_in(validated_workflow_options(), [:hooks])

    %{
      after_create: Map.get(hooks, :after_create),
      before_run: Map.get(hooks, :before_run),
      after_run: Map.get(hooks, :after_run),
      before_remove: Map.get(hooks, :before_remove),
      timeout_ms: Map.get(hooks, :timeout_ms)
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    get_in(validated_workflow_options(), [:hooks, :timeout_ms])
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    get_in(validated_workflow_options(), [:agent, :max_concurrent_agents])
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    get_in(validated_workflow_options(), [:agent, :max_retry_backoff_ms])
  end

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns do
    get_in(validated_workflow_options(), [:agent, :max_turns])
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    state_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_state])
    global_limit = max_concurrent_agents()
    Map.get(state_limits, normalize_issue_state(state_name), global_limit)
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec agent_turn_timeout_ms() :: pos_integer()
  def agent_turn_timeout_ms do
    get_in(validated_workflow_options(), [:agent, :turn_timeout_ms])
  end

  @spec agent_read_timeout_ms() :: pos_integer()
  def agent_read_timeout_ms do
    get_in(validated_workflow_options(), [:agent, :read_timeout_ms])
  end

  @spec agent_stall_timeout_ms() :: non_neg_integer()
  def agent_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:agent, :stall_timeout_ms])
    |> max(0)
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} when is_binary(prompt) ->
        if String.trim(prompt) == "", do: SymphonyElixir.Tracker.default_prompt_template(), else: prompt

      _ ->
        SymphonyElixir.Tracker.default_prompt_template()
    end
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    get_in(validated_workflow_options(), [:observability, :dashboard_enabled])
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    get_in(validated_workflow_options(), [:observability, :refresh_ms])
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    get_in(validated_workflow_options(), [:observability, :render_interval_ms])
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        get_in(validated_workflow_options(), [:server, :port])
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    get_in(validated_workflow_options(), [:server, :host])
  end

  @spec validate!() :: :ok | {:error, String.t()}
  def validate! do
    with {:ok, _workflow} <- current_workflow(),
         :ok <- tracker_config_module().validate!() do
      agent_config_module().validate!()
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Invalid WORKFLOW.md: #{inspect(reason)}"}
    end
  end

  defp tracker_config_module do
    case tracker_kind() do
      "linear" -> SymphonyElixir.Linear.Config
      "github" -> SymphonyElixir.GitHub.Config
      "memory" -> SymphonyElixir.Memory.Config
    end
  end

  defp agent_config_module do
    case agent_kind() do
      "codex" -> SymphonyElixir.Codex.Config
      "claude" -> SymphonyElixir.Claude.Config
    end
  end

  defp detect_sections(section_names) do
    config = workflow_config()
    Enum.filter(section_names, &Map.has_key?(config, &1))
  end

  defp validated_workflow_options do
    workflow_config()
    |> extract_workflow_options()
    |> NimbleOptions.validate!(@workflow_options_schema)
  end

  defp extract_workflow_options(config) do
    %{
      tracker: extract_tracker_options(section_map(config, "tracker")),
      polling: extract_polling_options(section_map(config, "polling")),
      workspace: extract_workspace_options(section_map(config, "workspace")),
      agent: extract_agent_options(section_map(config, "agent")),
      hooks: extract_hooks_options(section_map(config, "hooks")),
      observability: extract_observability_options(section_map(config, "observability")),
      server: extract_server_options(section_map(config, "server"))
    }
  end

  defp extract_tracker_options(section) do
    %{}
    |> put_if_present(:active_states, csv_value(Map.get(section, "active_states")))
    |> put_if_present(:terminal_states, csv_value(Map.get(section, "terminal_states")))
  end

  defp extract_polling_options(section) do
    %{}
    |> put_if_present(:interval_ms, integer_value(Map.get(section, "interval_ms")))
  end

  defp extract_workspace_options(section) do
    %{}
    |> put_if_present(:root, binary_value(Map.get(section, "root")))
  end

  defp extract_agent_options(section) do
    %{}
    |> put_if_present(:max_concurrent_agents, integer_value(Map.get(section, "max_concurrent_agents")))
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(:max_retry_backoff_ms, positive_integer_value(Map.get(section, "max_retry_backoff_ms")))
    |> put_if_present(
      :max_concurrent_agents_by_state,
      state_limits_value(Map.get(section, "max_concurrent_agents_by_state"))
    )
    |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
    |> put_if_present(:read_timeout_ms, integer_value(Map.get(section, "read_timeout_ms")))
    |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
  end

  defp extract_hooks_options(section) do
    %{}
    |> put_if_present(:after_create, hook_command_value(Map.get(section, "after_create")))
    |> put_if_present(:before_run, hook_command_value(Map.get(section, "before_run")))
    |> put_if_present(:after_run, hook_command_value(Map.get(section, "after_run")))
    |> put_if_present(:before_remove, hook_command_value(Map.get(section, "before_remove")))
    |> put_if_present(:timeout_ms, positive_integer_value(Map.get(section, "timeout_ms")))
  end

  defp extract_observability_options(section) do
    %{}
    |> put_if_present(:dashboard_enabled, boolean_value(Map.get(section, "dashboard_enabled")))
    |> put_if_present(:refresh_ms, integer_value(Map.get(section, "refresh_ms")))
    |> put_if_present(:render_interval_ms, integer_value(Map.get(section, "render_interval_ms")))
  end

  defp extract_server_options(section) do
    %{}
    |> put_if_present(:port, non_negative_integer_value(Map.get(section, "port")))
    |> put_if_present(:host, scalar_string_value(Map.get(section, "host")))
  end

  defp section_map(config, key) do
    case Map.get(config, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp put_if_present(map, _key, :omit), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp scalar_string_value(nil), do: :omit
  defp scalar_string_value(value) when is_binary(value), do: String.trim(value)
  defp scalar_string_value(value) when is_boolean(value), do: to_string(value)
  defp scalar_string_value(value) when is_integer(value), do: to_string(value)
  defp scalar_string_value(value) when is_float(value), do: to_string(value)
  defp scalar_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar_string_value(_value), do: :omit

  defp binary_value(value, opts \\ [])

  defp binary_value(value, opts) when is_binary(value) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    if value == "" and not allow_empty do
      :omit
    else
      value
    end
  end

  defp binary_value(_value, _opts), do: :omit

  defp hook_command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      _ -> String.trim_trailing(value)
    end
  end

  defp hook_command_value(_value), do: :omit

  defp csv_value(values) when is_list(values) do
    values
    |> Enum.reduce([], fn value, acc -> maybe_append_csv_value(acc, value) end)
    |> Enum.reverse()
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(_value), do: :omit

  defp maybe_append_csv_value(acc, value) do
    case scalar_string_value(value) do
      :omit ->
        acc

      normalized ->
        append_csv_value_if_present(acc, normalized)
    end
  end

  defp append_csv_value_if_present(acc, value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      acc
    else
      [trimmed | acc]
    end
  end

  defp integer_value(value) do
    case parse_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp positive_integer_value(value) do
    case parse_positive_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp non_negative_integer_value(value) do
    case parse_non_negative_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp boolean_value(value) when is_boolean(value), do: value

  defp boolean_value(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> :omit
    end
  end

  defp boolean_value(_value), do: :omit

  defp state_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {state_name, limit}, acc ->
      case parse_positive_integer(limit) do
        {:ok, parsed} ->
          Map.put(acc, normalize_issue_state(to_string(state_name)), parsed)

        :error ->
          acc
      end
    end)
  end

  defp state_limits_value(_value), do: :omit

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_positive_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_non_negative_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp workflow_config do
    case current_workflow() do
      {:ok, %{config: config}} when is_map(config) ->
        normalize_keys(config)

      _ ->
        %{}
    end
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp resolve_path_value(:missing, default), do: default
  defp resolve_path_value(nil, default), do: default

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      path ->
        path
        |> String.trim()
        |> preserve_command_name()
        |> then(fn
          "" -> default
          resolved -> resolved
        end)
    end
  end

  defp resolve_path_value(_value, default), do: default

  defp preserve_command_name(path) do
    cond do
      uri_path?(path) ->
        path

      String.contains?(path, "/") or String.contains?(path, "\\") ->
        Path.expand(path)

      true ->
        path
    end
  end

  defp uri_path?(path) do
    String.match?(to_string(path), ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)
  end

  defp normalize_path_token(value) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> trimmed
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(value) do
    case System.get_env(value) do
      nil -> :missing
      env_value -> env_value
    end
  end
end
