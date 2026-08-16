defmodule Aiur.Config.Schema.AgentValidation do
  @moduledoc "Normalizers and changeset validators for the agent section's map fields (state limits, complexity routing, complexity prompts) and normalize_issue_state/1."

  import Ecto.Changeset, only: [get_field: 2, validate_change: 3]

  alias Aiur.Config.RoutingValue

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  @doc false
  @spec normalize_agent_routing(nil | map()) :: map()
  def normalize_agent_routing(nil), do: %{}

  def normalize_agent_routing(routing) when is_map(routing) do
    Enum.reduce(routing, %{}, fn {level, backend}, acc ->
      Map.put(acc, normalize_routing_level(level), to_string(backend))
    end)
  end

  @doc false
  @spec validate_agent_routing(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_agent_routing(changeset, field) do
    known =
      ((get_field(changeset, :priority) || []) ++
         Aiur.CodingAgent.dispatchable_backends(get_field(changeset, :backend_configs) || %{}))
      |> Enum.uniq()

    openrouter = openrouter_section(get_field(changeset, :backend_configs) || %{})

    validate_change(changeset, field, fn ^field, routing ->
      Enum.flat_map(routing, fn {level, value} ->
        routing_errors(field, known, level, value) ++ auto_routing_config_errors(field, value, openrouter)
      end)
    end)
  end

  # Delegated OpenRouter routing (`openrouter:router/auto`) is only predictable
  # when the tier's provider policy pins how the upstream is chosen. Without a
  # provider.order or provider.sort, OpenRouter has no deterministic policy and
  # the resulting routing is unpredictable — reject at config load rather than
  # at request time (#1923).
  defp auto_routing_config_errors(field, value, openrouter) do
    {backend, model} = RoutingValue.split_routing_value(value)
    provider = if is_map(openrouter), do: provider_value(openrouter, "provider"), else: nil

    if backend == "openrouter" and model == "router/auto" and not openrouter_auto_policy?(provider) do
      [
        {field, "openrouter:router/auto needs a provider policy; set agent.backend_configs.openrouter.provider.order or .sort"}
      ]
    else
      []
    end
  end

  defp routing_errors(field, known, level, value) do
    cond do
      not is_integer(level) or level <= 0 ->
        [{field, "complexity levels must be positive integers"}]

      not is_binary(value) or RoutingValue.routing_backend(value) not in known ->
        [
          {field, "unknown or disabled backend #{inspect(value)}; dispatchable backends: #{inspect(known)} (optionally backend:model)"}
        ]

      RoutingValue.routing_remote_flag?(value) and
          not Aiur.CodingAgent.remote_control?(RoutingValue.routing_backend(value)) ->
        [{field, "+remote routing requires a remote-capable backend, got #{inspect(value)}"}]

      not valid_routing_effort?(value) ->
        invalid_routing_effort_error(field, value)

      true ->
        []
    end
  end

  defp invalid_routing_effort_error(field, value) do
    backend = routing_effort_backend(value)

    [
      {field,
       "invalid effort #{inspect(RoutingValue.routing_effort(value))} for backend #{inspect(backend)}; " <>
         "valid efforts: #{inspect(Aiur.CodingAgent.efforts(backend))}"}
    ]
  end

  # A routing value's optional effort segment must be in the backend's valid
  # set. No effort segment is always fine (the backend's own default applies).
  # The backend is already known here (an earlier cond branch rejects unknown
  # backends), so `efforts/1` returns its real set. `claude+remote` dispatches
  # through the interactive REPL transport, so validate its effort against that
  # transport rather than the headless app-server wrapper.
  defp valid_routing_effort?(value) do
    case RoutingValue.routing_effort(value) do
      nil -> true
      effort -> effort in Aiur.CodingAgent.efforts(routing_effort_backend(value))
    end
  end

  defp routing_effort_backend(value) do
    case {RoutingValue.routing_backend(value), RoutingValue.routing_remote_flag?(value)} do
      {"claude", true} -> "claude-repl"
      {backend, _remote?} -> backend
    end
  end

  @doc false
  @spec normalize_complexity_prompts(nil | map()) :: map()
  def normalize_complexity_prompts(nil), do: %{}

  def normalize_complexity_prompts(prompts) when is_map(prompts) do
    Enum.reduce(prompts, %{}, fn {level, text}, acc ->
      Map.put(acc, normalize_routing_level(level), text)
    end)
  end

  @doc false
  @spec validate_complexity_prompts(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_complexity_prompts(changeset, field) do
    validate_change(changeset, field, fn ^field, prompts ->
      Enum.flat_map(prompts, fn {level, text} ->
        cond do
          not is_integer(level) or level <= 0 ->
            [{field, "complexity levels must be positive integers"}]

          not is_binary(text) ->
            [{field, "complexity prompt values must be strings"}]

          true ->
            []
        end
      end)
    end)
  end

  @doc false
  @spec normalize_max_turns_by_complexity(nil | map()) :: map()
  def normalize_max_turns_by_complexity(nil), do: %{}

  def normalize_max_turns_by_complexity(caps) when is_map(caps) do
    Enum.reduce(caps, %{}, fn {level, cap}, acc ->
      Map.put(acc, normalize_routing_level(level), cap)
    end)
  end

  @doc false
  @spec validate_max_turns_by_complexity(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_max_turns_by_complexity(changeset, field) do
    validate_change(changeset, field, fn ^field, caps ->
      Enum.flat_map(caps, fn {level, cap} ->
        cond do
          not is_integer(level) or level <= 0 ->
            [{field, "complexity levels must be positive integers"}]

          not is_integer(cap) or cap <= 0 ->
            [{field, "max_turns_by_complexity values must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  @doc false
  @spec normalize_routing_level(integer() | String.t() | term()) :: integer() | term()
  def normalize_routing_level(level) when is_integer(level), do: level

  def normalize_routing_level(level) when is_binary(level) do
    case Integer.parse(level) do
      {n, ""} -> n
      _ -> level
    end
  end

  def normalize_routing_level(level), do: level

  # ---------------------------------------------------------------------------
  # Nested OpenRouter routing tier (#1923).
  #
  # `agent.backend_configs.openrouter` may carry a `model` (the tier's default
  # model, typically `router/auto` or a concrete upstream path) and a `provider`
  # map that maps onto OpenRouter's `provider` request object (order /
  # allow_fallbacks / ignore / sort / route / max_retries). All keys are
  # optional and additive: an existing flat openrouter config (or no section at
  # all) stays valid and behaves exactly as before.
  # ---------------------------------------------------------------------------

  @openrouter_sorts ~w(price throughput latency none)
  @openrouter_routes ~w(any undefined)
  @openrouter_provider_keys ~w(order allow_fallbacks ignore sort route max_retries)

  @doc false
  @spec validate_openrouter_backend_config(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_openrouter_backend_config(changeset) do
    validate_change(changeset, :backend_configs, fn :backend_configs, configs ->
      case openrouter_section(configs || %{}) do
        nil -> []
        section when is_map(section) -> openrouter_section_errors(section)
        _ -> [backend_configs: "openrouter must be a map"]
      end
    end)
  end

  defp openrouter_section(configs) do
    case configs do
      map when is_map(map) -> Map.get(map, "openrouter") || Map.get(map, :openrouter)
      _ -> nil
    end
  end

  defp openrouter_section_errors(section) do
    model_errors(section) ++ provider_errors(section) ++ auto_policy_errors(section)
  end

  defp model_errors(section) do
    case section_model(section) do
      nil -> []
      model when is_binary(model) and model != "" -> []
      _ -> [backend_configs: "openrouter.model must be a non-empty string"]
    end
  end

  defp provider_errors(section) do
    case provider_value(section) do
      nil -> []
      provider when is_map(provider) -> provider_field_errors(provider)
      _ -> [backend_configs: "openrouter.provider must be a map"]
    end
  end

  defp provider_field_errors(provider) do
    Enum.flat_map(provider, fn {key, value} ->
      case provider_key(key) do
        "order" -> provider_string_list_errors("order", value)
        "ignore" -> provider_string_list_errors("ignore", value)
        "allow_fallbacks" -> provider_boolean_errors("allow_fallbacks", value)
        "sort" -> provider_enum_errors("sort", value, @openrouter_sorts)
        "route" -> provider_enum_errors("route", value, @openrouter_routes)
        "max_retries" -> provider_integer_errors("max_retries", value)
        nil -> [backend_configs: "openrouter.provider.#{key} is not a supported OpenRouter provider parameter"]
      end
    end)
  end

  # A `model: router/auto` tier default is only predictable when the provider
  # policy pins how the upstream is chosen (order or a non-none sort).
  defp auto_policy_errors(section) do
    if section_model(section) == "router/auto" and not openrouter_auto_policy?(provider_value(section)) do
      [
        backend_configs: "openrouter.model router/auto needs a provider policy; set openrouter.provider.order or a non-none openrouter.provider.sort"
      ]
    else
      []
    end
  end

  # Whether the provider policy pins an upstream choice for `router/auto`: an
  # explicit `order` list or a `sort` other than `none`.
  defp openrouter_auto_policy?(provider) do
    case provider do
      nil ->
        false

      map when is_map(map) ->
        order = provider_value(map, "order")
        sort = provider_value(map, "sort")
        (is_list(order) and order != []) or (is_binary(sort) and sort != "none")
    end
  end

  defp provider_string_list_errors(name, value) do
    if is_list(value) and Enum.all?(value, &(is_binary(&1) and &1 != "")),
      do: [],
      else: [backend_configs: "openrouter.provider.#{name} must be a list of non-empty strings"]
  end

  defp provider_boolean_errors(name, value) do
    if is_boolean(value), do: [], else: [backend_configs: "openrouter.provider.#{name} must be a boolean"]
  end

  defp provider_enum_errors(name, value, allowed) do
    if is_binary(value) and value in allowed,
      do: [],
      else: [backend_configs: "openrouter.provider.#{name} must be one of #{inspect(allowed)}"]
  end

  defp provider_integer_errors(name, value) do
    if is_integer(value) and value > 0,
      do: [],
      else: [backend_configs: "openrouter.provider.#{name} must be a positive integer"]
  end

  defp section_model(section), do: provider_value(section, "model")
  defp provider_value(section), do: provider_value(section, "provider")
  defp provider_value(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp provider_key(key) when is_binary(key) do
    if key in @openrouter_provider_keys, do: key
  end

  defp provider_key(key) when is_atom(key) do
    key_str = Atom.to_string(key)
    if key_str in @openrouter_provider_keys, do: key_str
  end

  defp provider_key(_key), do: nil
end
