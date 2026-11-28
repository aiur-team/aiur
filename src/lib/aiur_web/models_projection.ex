defmodule AiurWeb.ModelsProjection do
  @moduledoc "Configured model routes and their current dispatch and usage state."

  alias Aiur.{Accounts, CodingAgent, Config, ModelAvailability}
  alias Aiur.CodingAgent.CapacityGate
  alias Aiur.Config.RoutingValue

  @windows ["five_hour", "seven_day", "hourly", "weekly", "monthly"]

  @doc "Returns configured model routes in the order dispatch considers them."
  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    settings = safe(fn -> Config.settings!() end, nil)
    priority = settings_priority(settings)
    route_opts = Keyword.put(opts, :legacy_routes, settings_legacy_routes(settings))
    routing = safe(fn -> Config.agent_routing_candidates() end, %{})
    routes = ordered_routes(priority, routing, settings)
    meters = Keyword.get(opts, :meters, %{})
    availability = Keyword.get_lazy(opts, :availability, &ModelAvailability.load/0)

    %{
      observed_at: now,
      account_selection: settings_account_selection(settings),
      routes: routes |> Enum.with_index() |> Enum.map(fn {route, index} -> route_for(route, index, priority, meters, availability, now, route_opts) end)
    }
  end

  @doc false
  @spec ordered_routes([String.t()], map()) :: [String.t()]
  def ordered_routes(priority, routing) do
    ordered_routes(priority, routing, nil)
  end

  defp ordered_routes(priority, routing, settings) do
    priority = if priority == [], do: settings_routes(settings), else: priority
    routed = routing |> Enum.sort_by(fn {level, _} -> level end) |> Enum.flat_map(fn {_level, values} -> List.wrap(values) end)
    candidates = priority ++ routed

    candidates
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp settings_priority(%{agent: %{priority: values}}), do: values || []
  defp settings_priority(_), do: []

  defp settings_routes(settings), do: settings_priority(settings) ++ settings_legacy_routes(settings)
  defp settings_legacy_routes(%{agent: agent}), do: Map.get(agent, :switch_model_on_ratelimit) || []
  defp settings_legacy_routes(_), do: []

  defp settings_account_selection(%{agent: agent}), do: Map.get(agent, :account_selection)
  defp settings_account_selection(_), do: nil

  @doc false
  @spec route_for(String.t(), non_neg_integer(), [String.t()], map(), map(), DateTime.t(), keyword()) :: map()
  def route_for(route, index, priority, meters, availability, now, opts \\ []) do
    backend = RoutingValue.routing_backend(route)
    backend_config = safe(fn -> Map.get(Config.agent_backend_configs(), backend, %{}) end, %{})
    configured_model = Map.get(backend_config, "model") || Map.get(backend_config, :model) || Map.get(backend_config, "default_model") || Map.get(backend_config, :default_model)
    model = RoutingValue.routing_model(route) || configured_model || safe(fn -> CodingAgent.resolve_model(backend, nil) end, nil)
    effort = RoutingValue.routing_effort(route)
    family = safe(fn -> CodingAgent.family_for(backend) end, nil)
    accounts = configured_accounts(backend)
    meter = if is_binary(family), do: Map.get(meters, String.to_existing_atom(family)), else: nil
    windows = usage_windows(meter, backend, availability, now)

    %{
      position: index + 1,
      backend: backend,
      model: model,
      effort: effort,
      accounts: Enum.map(accounts, &%{name: &1, freshness: "unknown"}),
      source: route_source(route, priority, opts),
      dispatch: dispatch_state(route, backend, availability, now, opts),
      usage: %{state: if(Enum.any?(windows, &is_number(&1.used_percent)), do: "known", else: "unknown"), windows: windows}
    }
  end

  defp dispatch_state(route, backend, availability, now, opts) do
    dispatchable = safe(fn -> CodingAgent.RouteCredentials.usable?(route) end, false)
    limited = not ModelAvailability.available?(backend, state: availability, now: now)
    missing_key = CodingAgent.RouteCredentials.missing_key_env(route)
    capacity = Keyword.get_lazy(opts, :capacity, fn -> capacity_status(route) end)

    %{
      available: dispatchable and not limited and capacity_available?(capacity),
      reason: dispatch_reason(missing_key, limited, capacity)
    }
  end

  defp usage_windows(meter, backend, availability, now) do
    provider_windows = if is_struct(meter, Aiur.ProviderMeterSnapshot), do: meter.windows, else: %{}

    Enum.map(@windows, fn name ->
      provider = provider_window(provider_windows, name)
      ledger = get_in(availability, ["backends", ModelAvailability.backend_key(backend), ledger_key(name)])
      window = provider
      used = first_present(value(window, :used_percent), ledger_used(ledger, now))
      reset_at = first_present(value(window, :resets_at), ledger_reset(ledger))
      freshness = if is_number(used), do: value(window, :freshness) || meter_freshness(meter), else: "unknown"
      %{name: name, used_percent: used, reset_at: reset_at, freshness: freshness}
    end)
  end

  defp provider_window(windows, name) when is_map(windows) do
    Enum.find_value(windows, fn {key, window} -> if to_string(key) == name, do: window end)
  end

  defp provider_window(_, _), do: nil
  defp meter_freshness(%Aiur.ProviderMeterSnapshot{freshness: freshness}), do: Atom.to_string(freshness)
  defp meter_freshness(_), do: "observed"

  defp configured_accounts(backend) do
    harness = account_backend(backend)
    configured = Accounts.configured_names(harness)
    if configured == [], do: ["default"], else: configured
  rescue
    _ -> ["default"]
  end

  defp account_backend(backend), do: if(CodingAgent.family_for(backend), do: CodingAgent.family_for(backend), else: backend)
  defp ledger_key("five_hour"), do: "hourly"
  defp ledger_key("seven_day"), do: "weekly"
  defp ledger_key(name), do: name

  defp ledger_used(%{"used" => used, "limit" => limit} = entry, now) when is_number(used) and is_number(limit) and limit > 0 do
    if reset_at = ledger_reset(entry), do: if(DateTime.compare(reset_at, now) == :gt, do: used / limit * 100, else: nil), else: used / limit * 100
  end

  defp ledger_used(_, _), do: nil
  defp ledger_reset(%{"reset_at" => value}) when is_integer(value), do: DateTime.from_unix!(value)

  defp ledger_reset(%{"reset_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> date
      _ -> nil
    end
  end

  defp ledger_reset(_), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_, _), do: nil
  defp first_present(nil, fallback), do: fallback
  defp first_present(value, _fallback), do: value
  defp dispatch_reason(env, _, _) when is_binary(env), do: "missing_credentials:#{env}"
  defp dispatch_reason(_, true, _), do: "limit_reached"

  defp dispatch_reason(_, _, %{status: status, reason: reason}) when status in [:hold, :defer],
    do: "capacity_#{reason || status}"

  defp dispatch_reason(_, _, _), do: nil

  defp capacity_available?(nil), do: true
  defp capacity_available?(%{status: :allow}), do: true
  defp capacity_available?(_), do: false

  defp route_source(route, priority, opts) do
    cond do
      route in priority -> "agent.priority"
      route in Keyword.get(opts, :legacy_routes, []) -> "agent.switch_model_on_ratelimit"
      true -> "agent.routing"
    end
  end

  defp capacity_status(route) do
    case safe(fn -> CapacityGate.record([route]) end, nil) do
      %{candidates: [%{status: status, reason: reason}]} when status in [:allow, :hold, :defer] -> %{status: status, reason: reason}
      _ -> nil
    end
  end

  defp safe(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end
end
