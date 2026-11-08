defmodule Aiur.Config.Schema.OpenRouterBackend do
  @moduledoc """
  Validation and request shaping for OpenRouter's own routing controls.

  There are two ways to choose an OpenRouter upstream. **Pinned:** the
  operator names providers in a fixed order. **Handed off:** aiur forwards
  OpenRouter's routing fields (a model set, a price sort, price caps), and
  OpenRouter picks the upstream. `agent.backend_configs.openrouter.provider`
  carries both, and `agent.backend_configs.openrouter.routes` overrides it per
  route.

  Validation runs at config load, so a misspelled field is a config error
  rather than a request OpenRouter silently ignores. Shaping runs when a
  session resolves its model, because that is the first point where the
  route's model segment is known.
  """

  alias Aiur.Config.RoutingValue

  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.order | array of strings or nil | omitted | Preferred upstream providers, most preferred first. |
  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.only | array of strings or nil | omitted | Restricts a request to these upstream providers. |
  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.ignore | array of strings or nil | omitted | Upstream providers to exclude. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.allow_fallbacks | boolean or nil | omitted | Whether OpenRouter may cross to another upstream within one request. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.sort | string or nil | omitted | `price`, `throughput`, or `latency`. `price` with no `order` means "cheapest available". |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.max_price | map or nil | omitted | Price cap per million tokens, as `{prompt: <number>, completion: <number>}`; OpenRouter skips upstreams priced above it. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.quantizations | array of strings or nil | omitted | Restricts the request to these quantization levels (`int4`, `int8`, `fp8`, `fp16`, `bf16`, `fp32`, `unknown`). |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.data_collection | string or nil | omitted | `allow` or `deny`: whether a request may route to upstreams that train on or retain prompts. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.require_parameters | boolean or nil | omitted | Only route to upstreams that support every request parameter aiur sends. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.routes | map | `%{}` | Per-route overrides keyed by the route's model segment or by a named model set. Each entry takes `provider` (same fields as the block above) and/or `models` (a non-empty list of model slugs). |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.routes.<route>.provider | map or nil | omitted | Provider preferences for this route only, layered over `agent.backend_configs.openrouter.provider`. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.routes.<route>.models | array of strings or nil | omitted | Names a model set: the route sends these as OpenRouter's `models` list and the first one is its primary model. |

  @type config :: map()

  @provider_fields ~w(order only ignore allow_fallbacks sort max_price quantizations data_collection require_parameters)
  @route_fields ~w(models provider)
  @sorts ~w(price throughput latency)
  @data_collection ~w(allow deny)
  @max_price_fields ~w(prompt completion)

  @doc "The provider field names aiur forwards, in documented order."
  @spec provider_fields() :: [String.t()]
  def provider_fields, do: @provider_fields

  @doc """
  Rejects unknown or malformed OpenRouter routing settings.

  Only the routing blocks are checked here — `provider` and `routes`. The rest
  of the backend section (`model`, `base_url`, `enabled`, `quirks`, …) belongs
  to the generic OpenAI-compatible backend and is validated elsewhere.
  """
  @spec validate(config()) :: :ok | {:error, String.t()}
  def validate(config) when is_map(config) do
    config = stringify_keys(config)

    with :ok <- validate_provider(Map.get(config, "provider"), "provider") do
      validate_routes(Map.get(config, "routes"))
    end
  end

  def validate(_config), do: {:error, "must be a map"}

  @doc """
  Shapes one resolved session config for its route.

  `model` is the model segment the operator routed to: a single model slug, an
  inline set (`{vendor/a, vendor/b}`), or the name of a `routes` entry. Sets
  expand into OpenRouter's `models` list, a route entry layers its `provider`
  block over the backend block, and a set with no pinned order defaults to
  `sort: price` — the "cheapest available" mode.
  """
  @spec apply_route(config(), String.t() | nil) :: config()
  def apply_route(config, model) when is_map(config) do
    route = route_entry(config, model)
    models = route_models(route, model)

    config
    |> put_optional(:model, List.first(List.wrap(models)) || model)
    |> put_optional(:models, models)
    |> put_optional(:provider, route_provider(config, route, models))
  end

  # --- routes ---------------------------------------------------------------

  defp route_entry(config, model) when is_binary(model) do
    case Map.get(stringify_keys(config), "routes") do
      routes when is_map(routes) ->
        case Map.get(stringify_keys(routes), model) do
          entry when is_map(entry) ->
            entry = stringify_keys(entry)
            %{models: non_empty_list(Map.get(entry, "models")), provider: Map.get(entry, "provider")}

          _absent ->
            nil
        end

      _absent ->
        nil
    end
  end

  defp route_entry(_config, _model), do: nil

  @doc """
  Whether `model` names a `routes` entry of this backend's config, i.e. an
  operator-declared route rather than a model aiur should recognise.
  """
  @spec named_route?(config(), String.t() | nil) :: boolean()
  def named_route?(config, model) when is_map(config) and is_binary(model) do
    case Map.get(stringify_keys(config), "routes") do
      routes when is_map(routes) -> Map.has_key?(stringify_keys(routes), model)
      _absent -> false
    end
  end

  def named_route?(_config, _model), do: false

  defp route_models(%{models: models}, _model) when is_list(models), do: models

  defp route_models(_route, model) do
    case RoutingValue.model_set(model) do
      {:ok, models} -> models
      :error -> nil
    end
  end

  defp route_provider(config, route, models) do
    backend = stringify_keys(Map.get(config, :provider))
    override = stringify_keys(route && route.provider)
    merged = Map.merge(backend, override)

    cond do
      is_list(models) and not Map.has_key?(merged, "sort") and not Map.has_key?(merged, "order") ->
        Map.put(merged, "sort", "price")

      map_size(merged) == 0 ->
        nil

      true ->
        merged
    end
  end

  # --- validation -----------------------------------------------------------

  defp validate_routes(nil), do: :ok

  defp validate_routes(routes) when is_map(routes) do
    Enum.reduce_while(routes, :ok, fn {name, entry}, :ok ->
      case validate_route(name, entry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_routes(other), do: {:error, "routes must be a map of route name to settings, got #{inspect(other)}"}

  defp validate_route(name, entry) when is_map(entry) do
    entry = stringify_keys(entry)

    with :ok <- validate_route_name(name),
         :ok <- reject_unknown(Map.keys(entry), @route_fields, "routes.#{name}"),
         :ok <- validate_models_field(name, Map.get(entry, "models")) do
      validate_provider(Map.get(entry, "provider"), "routes.#{name}.provider")
    end
  end

  defp validate_route(name, _entry), do: {:error, "routes.#{name} must be a map"}

  defp validate_route_name(name) do
    name = to_string(name)

    cond do
      String.trim(name) == "" ->
        {:error, "routes must use non-blank names"}

      String.contains?(name, [":", "{", "}"]) ->
        {:error, "routes.#{name} cannot be written as a route: a route name may not contain `:`, `{` or `}`"}

      String.ends_with?(name, "+remote") ->
        {:error, "routes.#{name} cannot be written as a route: the name ends with the reserved `+remote` flag"}

      true ->
        :ok
    end
  end

  defp validate_models_field(_name, nil), do: :ok
  defp validate_models_field(name, models) when is_list(models) and models != [], do: validate_model_list(models, "routes.#{name}.models")
  defp validate_models_field(name, _models), do: {:error, "routes.#{name}.models must be a non-empty list of model slugs"}

  defp validate_model_list(models, path) do
    if Enum.all?(models, &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else: {:error, "#{path} must be a list of non-blank model slugs"}
  end

  defp validate_provider(nil, _path), do: :ok

  defp validate_provider(provider, path) when is_map(provider) do
    provider = stringify_keys(provider)

    with :ok <- reject_unknown(Map.keys(provider), @provider_fields, path),
         :ok <- validate_string_list(provider, "order", path),
         :ok <- validate_string_list(provider, "only", path),
         :ok <- validate_string_list(provider, "ignore", path),
         :ok <- validate_string_list(provider, "quantizations", path),
         :ok <- validate_boolean(provider, "allow_fallbacks", path),
         :ok <- validate_boolean(provider, "require_parameters", path),
         :ok <- validate_enum(provider, "sort", @sorts, path),
         :ok <- validate_enum(provider, "data_collection", @data_collection, path) do
      validate_max_price(provider, path)
    end
  end

  defp validate_provider(provider, path), do: {:error, "#{path} must be a map, got #{inspect(provider)}"}

  defp reject_unknown(keys, allowed, path) do
    case Enum.find(keys, &(to_string(&1) not in allowed)) do
      nil -> :ok
      key -> {:error, "#{path} has an unknown field #{inspect(to_string(key))}; allowed fields: #{Enum.join(allowed, ", ")}"}
    end
  end

  defp validate_string_list(map, field, path) do
    case Map.get(map, field) do
      nil ->
        :ok

      values when is_list(values) and values != [] ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
          do: :ok,
          else: {:error, "#{path}.#{field} must be a list of non-blank strings"}

      _other ->
        {:error, "#{path}.#{field} must be a list of strings"}
    end
  end

  defp validate_boolean(map, field, path) do
    case Map.get(map, field) do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _other -> {:error, "#{path}.#{field} must be true or false"}
    end
  end

  defp validate_enum(map, field, allowed, path) do
    case Map.get(map, field) do
      nil -> :ok
      value -> if value in allowed, do: :ok, else: {:error, "#{path}.#{field} must be one of #{Enum.join(allowed, ", ")}"}
    end
  end

  defp validate_max_price(map, path) do
    case Map.get(map, "max_price") do
      nil -> :ok
      price when is_map(price) and map_size(price) > 0 -> validate_price_fields(stringify_keys(price), "#{path}.max_price")
      _other -> {:error, "#{path}.max_price must be a map with prompt and/or completion prices"}
    end
  end

  defp validate_price_fields(price, path) do
    case reject_unknown(Map.keys(price), @max_price_fields, path) do
      :ok -> reduce_prices(price, path)
      error -> error
    end
  end

  defp reduce_prices(price, path) do
    Enum.reduce_while(price, :ok, fn {field, value}, :ok ->
      case validate_price_value(value, path, field) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_price_value(value, _path, _field) when is_number(value) and value >= 0, do: :ok

  defp validate_price_value(_value, path, field),
    do: {:error, "#{path}.#{field} must be a non-negative price per million tokens"}

  # --- helpers --------------------------------------------------------------

  defp non_empty_list(values) when is_list(values) and values != [], do: values
  defp non_empty_list(_values), do: nil

  # Settings reach this module from YAML with string keys and from the
  # atomized runtime config with atom keys; both shapes mean the same thing.
  defp stringify_keys(nil), do: %{}
  defp stringify_keys(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp stringify_keys(_other), do: %{}

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
