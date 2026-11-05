defmodule Aiur.Usage.Provider.OpenRouter do
  @moduledoc """
  OpenRouter usage: the credit standing of the key plus what each configured
  `openrouter:` route has actually spent.

  Two authorities answer two questions, and this adapter keeps them apart:

    * the retained provider-meter projection answers "how much credit is left",
      observed by the OpenAI-compatible meter probe with
      `OPENROUTER_MANAGEMENT_KEY`;
    * the crash-safe usage aggregate answers "what did each route and model
      spend", re-priced exactly as the dashboard prices it.

  A route with no recorded reading says so (`:no_reading`) instead of reporting
  an error or a zero. A key with no observation reports `:unknown` freshness and
  no credit figure at all — never `0 remaining`.
  """

  alias Aiur.CodingAgent.HeadroomDispatch
  alias Aiur.Config.{AgentSettings, RoutingValue}
  alias Aiur.Usage.Provider.OpenRouter.Spend
  alias Aiur.Usage.ProviderSupport

  defstruct [:provider, :observed_at, :age_ms, :freshness, :source, fields: %{}]
  @type t :: %__MODULE__{}

  @credit_window "credits-remaining"
  @backend "openrouter"

  @spec read(keyword()) :: t()
  def read(opts) do
    view = meter_view(opts)
    spend = spend(opts)
    routes = routes(opts)

    ProviderSupport.record(
      __MODULE__,
      :openrouter,
      Map.get(view, :observed_at),
      Map.get(view, :freshness, :unknown),
      %{
        state: state(view, spend),
        routes: route_entries(routes, spend),
        credits: credits(view),
        spend_source: "usage.aggregate"
      },
      "provider_meter_projection"
    )
  end

  # --- meter projection ---------------------------------------------------

  defp meter_view(opts) do
    views = Keyword.get_lazy(opts, :meter_views, &Aiur.ProviderMeterProjection.snapshot/0)
    Map.get(views, :openrouter, unknown_view())
  rescue
    _error -> unknown_view()
  catch
    _kind, _reason -> unknown_view()
  end

  defp unknown_view, do: %{state: :unknown, observed_at: nil, freshness: :unknown, windows: %{}}

  defp credits(view) do
    case Map.get(view, :windows, %{}) |> Map.get(@credit_window) do
      %{} = window ->
        %{
          remaining: number(Map.get(window, :remaining)),
          limit: number(Map.get(window, :limit)),
          used_percent: number(Map.get(window, :used_percent))
        }

      _absent ->
        nil
    end
  end

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  defp state(view, spend) do
    cond do
      credits(view) != nil -> :observed
      spend_entries(spend) != [] -> :observed
      true -> :no_reading
    end
  end

  # --- routes and spend ---------------------------------------------------

  defp routes(opts) do
    case Keyword.fetch(opts, :openrouter_routes) do
      {:ok, routes} when is_list(routes) -> routes
      {:ok, _other} -> []
      :error -> configured_routes()
    end
  end

  # Every configured route that names OpenRouter, from `agent.priority` and the
  # per-complexity routing lists. Config is read defensively: a usage snapshot
  # must stay readable while the config is unavailable.
  defp configured_routes do
    (AgentSettings.agent_priority() ++ routing_candidates())
    |> Enum.filter(&(RoutingValue.routing_backend(&1) == @backend))
    |> Enum.uniq()
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp routing_candidates do
    HeadroomDispatch.routing_candidates()
    |> Map.values()
    |> Enum.flat_map(&List.wrap/1)
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp spend(opts) do
    Keyword.get_lazy(opts, :openrouter_spend, fn -> Spend.by_model(Spend.default_source()) end)
  end

  defp spend_entries(spend) do
    Map.get(spend, :api_equivalent, []) ++ Map.get(spend, :provider_reported, [])
  end

  defp route_entries(routes, spend) do
    configured = Enum.map(routes, &route_entry/1)
    unconfigured = configured |> Enum.map(& &1.model) |> unconfigured_entries(spend)
    Enum.map(configured, &with_readings(&1, spend)) ++ unconfigured
  end

  defp route_entry(route) do
    %{route: route, model: model(route), state: :no_reading, readings: []}
  end

  defp with_readings(entry, spend) do
    readings = readings(spend, entry.model)
    %{entry | readings: readings, state: if(readings == [], do: :no_reading, else: :observed)}
  end

  # Spend recorded for a model no configured route names any more is still the
  # operator's spend; it is listed under the route slug the ledger resolved.
  defp unconfigured_entries(configured_models, spend) do
    spend
    |> spend_entries()
    |> Enum.map(& &1.model)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in configured_models))
    |> Enum.map(fn model ->
      %{route: @backend <> ":" <> to_string(model), model: model, state: :observed, readings: readings(spend, model)}
    end)
  end

  defp readings(spend, model) do
    spend
    |> Map.get(:api_equivalent, [])
    |> tagged(model, "api_equivalent")
    |> Kernel.++(tagged(Map.get(spend, :provider_reported, []), model, "provider_reported"))
  end

  defp tagged(entries, model, basis) do
    entries
    |> Enum.filter(&(&1.model == model))
    |> Enum.map(&Map.put(&1, :basis, basis))
  end

  defp model(route) do
    RoutingValue.routing_model(route)
  rescue
    _error -> nil
  end
end
