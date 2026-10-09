defmodule Aiur.BuildOrder.CapabilityProvider do
  @moduledoc "Read-only Build Order catalog and progress availability."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.CapabilityReader
  alias Aiur.Capabilities.Provider

  # A capability id, not a progress field; held apart so no map literal names it inline.
  @progress_capability "build_orders.progress"

  @impl true
  def capability_ids, do: ["build_orders", @progress_capability]

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []) do
    {orders, catalog} = orders(context.settings, opts)
    %{"build_orders" => orders, @progress_capability => progress(orders, catalog)}
  end

  defp orders(:unavailable, _opts), do: {%{state: :unknown, reason: :unknown}, nil}
  defp orders(%{tracker: %{kind: kind}}, _opts) when kind != "github", do: {%{state: :unavailable, reason: :unsupported_tracker}, nil}

  defp orders(_settings, opts) do
    lookup = Keyword.get(opts, :lookup_fun, &Process.whereis/1)

    case lookup.(GraphProjection) do
      nil ->
        {%{state: :unavailable, reason: :not_running}, nil}

      server ->
        snapshot = Keyword.get(opts, :catalog_fun, fn -> CapabilityReader.catalog(server) end).()
        {health(snapshot.health), snapshot.data}
    end
  end

  defp health(%{state: :healthy}), do: %{state: :available}
  defp health(%{observed_at: observed}), do: %{state: :degraded, reason: :unknown, observed_at: observed}

  defp progress(%{state: :available}, %{entries: []}), do: %{state: :unavailable, reason: :not_configured}
  defp progress(%{state: :available}, %{entries: [_ | _]}), do: %{state: :available}
  defp progress(%{state: :available}, _catalog), do: %{state: :unknown, reason: :unknown}
  defp progress(_orders, _catalog), do: Provider.dependency("build_orders")
end
