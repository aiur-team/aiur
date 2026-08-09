defmodule AiurWeb.FinancialData.ChangeBridge do
  @moduledoc """
  Bridges daemon-owned financial-data changes into the protected financial-data
  facade (DASH-021).

  When the usage projection advances or a provider meter is observed, authorized
  dashboard connections must be told to refresh. This worker observes the
  value-free `usage-aggregate:changed` signal and the provider-meter observed
  fanout, and asks `AiurWeb.FinancialData` to broadcast a payload-free `:updated`
  notification to each currently-authorized connection. It carries no financial
  value and makes no authorization decision: authorization and payload-free
  delivery remain entirely owned by the facade.

  Provider-meter observations ride the same bridge because a focused dashboard
  must reflect a fresh balance promptly: the daemon re-probes on focus and on
  the watch cadence, and the projection retains the result, but the dashboard
  only re-reads the projection when the facade tells it to. Without this
  subscription an open card would keep showing the previous observation until a
  manual page reload (issue #1550).
  """

  use GenServer

  alias Aiur.ProviderMeters.Events
  alias Aiur.UsageAggregate
  alias AiurWeb.FinancialData

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    subscribe_fun = Keyword.get(opts, :subscribe_fun, &UsageAggregate.subscribe/0)
    provider_meter_subscribe_fun = Keyword.get(opts, :provider_meter_subscribe_fun, &Events.subscribe_observed/0)
    broadcast_fun = Keyword.get(opts, :broadcast_fun, &FinancialData.broadcast_update/0)
    _ = safe_subscribe(subscribe_fun)
    _ = safe_subscribe(provider_meter_subscribe_fun)
    {:ok, %{broadcast_fun: broadcast_fun}}
  end

  @impl true
  def handle_info({:usage_aggregate_changed, _payload}, state) do
    _ = safe_broadcast(state.broadcast_fun)
    {:noreply, state}
  end

  # A provider meter observation (balance, credits, rate limits) is a financial
  # fact the dashboard displays; relay it so an authorized open card re-reads
  # the projection rather than holding its previous value.
  def handle_info({:provider_meter_changed, _snapshot}, state) do
    _ = safe_broadcast(state.broadcast_fun)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Subscribing before Aiur.PubSub is up would raise; tolerate it so the bridge
  # boots and simply receives nothing until the pubsub and projection exist.
  defp safe_subscribe(fun) do
    fun.()
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp safe_broadcast(fun) do
    fun.()
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
