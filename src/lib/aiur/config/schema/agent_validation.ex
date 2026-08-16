defmodule Aiur.Config.Schema.AgentValidation do
  @moduledoc "Normalizers and changeset validators for the agent section's map fields (state limits, complexity routing, complexity prompts) and normalize_issue_state/1."

  import Ecto.Changeset, only: [get_field: 2, validate_change: 3]

  alias Aiur.CodingAgent
  alias Aiur.CodingAgent.Models
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

  @doc """
  Validates `agent.priority` as an ordered list of **routes** rather than bare
  backend names. Each entry is a `Aiur.Config.RoutingValue` —
  `backend[:model[:effort]][+remote]` — the same grammar `agent.routing` has
  always accepted, so `[claude, "openrouter:anthropic/claude-sonnet-5", codex]`
  is expressible and a colon-free entry still parses to `{backend, nil}`, which
  is exactly today's meaning. Existing configs are therefore unaffected.

  Two rules differ from the pre-route validation:

    * duplicates are rejected per **routing value**, not per backend, or
      `[claude, "openrouter:claude"]` (two routes to one model, which is the
      whole point of the feature) would be refused while `[openrouter:a,
      openrouter:b]` would be too;
    * a backend that cannot name a default model — OpenRouter, which serves a
      catalog rather than one model — must carry an explicit model segment.
      This turns what used to be a runtime `:missing_model` into a config error.

  An unrecognized *model* is deliberately **not** an error: aiur's model list
  lags the provider by design (see `Aiur.CodingAgent.known_model?/2`).
  """
  @spec validate_agent_priority(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_agent_priority(changeset, field) do
    validate_change(changeset, field, fn ^field, routes ->
      known = Aiur.CodingAgent.known_backends()

      if routes == Enum.uniq(routes) do
        routes |> Enum.find_value(&priority_route_error(field, known, &1)) |> List.wrap()
      else
        [{field, "must not contain duplicate routes"}]
      end
    end)
  end

  defp priority_route_error(field, known, route) do
    backend = RoutingValue.routing_backend(route)

    cond do
      not is_binary(route) or backend not in known ->
        {field, "contains an unknown backend #{inspect(route)}; known backends: #{inspect(known)} (optionally backend:model)"}

      RoutingValue.routing_remote_flag?(route) and not CodingAgent.remote_control?(backend) ->
        {field, "+remote routing requires a remote-capable backend, got #{inspect(route)}"}

      not valid_routing_effort?(route) ->
        field |> invalid_routing_effort_error(route) |> List.first()

      true ->
        priority_model_error(field, backend, route)
    end
  end

  defp priority_model_error(field, backend, route) do
    model = RoutingValue.routing_model(route)

    cond do
      is_nil(model) and CodingAgent.model_required?(backend) ->
        {field, "backend #{inspect(backend)} serves a model catalog and needs an explicit model: #{backend}:<model>"}

      is_binary(model) and String.starts_with?(model, "~") ->
        {field,
         "model #{inspect(model)} in #{inspect(route)} starts with `~`; these aggregator ids are floating " <>
           "pointers whose target can change under a running fleet. Pin the concrete slug."}

      ambiguous_alias?(backend, model) ->
        {field, "model alias #{inspect(model)} in #{inspect(route)} matches more than one vendor; name the full slug instead"}

      true ->
        nil
    end
  end

  # An alias only resolves if exactly one vendor claims the family. Two vendors
  # shipping a `claude-*` would make `openrouter:claude` a coin flip between
  # two differently-priced upstreams, so reject it at config load rather than
  # picking one silently at dispatch.
  defp ambiguous_alias?(backend, model) do
    is_binary(model) and CodingAgent.model_aliases(backend) != [] and
      Models.ambiguous_alias?(CodingAgent.models(backend), model)
  end

  @doc false
  @spec validate_agent_routing(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_agent_routing(changeset, field) do
    known =
      (Enum.map(get_field(changeset, :priority) || [], &RoutingValue.routing_backend/1) ++
         Aiur.CodingAgent.dispatchable_backends(get_field(changeset, :backend_configs) || %{}))
      |> Enum.uniq()

    validate_change(changeset, field, fn ^field, routing ->
      Enum.flat_map(routing, fn {level, value} ->
        routing_errors(field, known, level, value)
      end)
    end)
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
end
