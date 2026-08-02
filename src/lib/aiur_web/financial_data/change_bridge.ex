defmodule AiurWeb.FinancialData.ChangeBridge do
  @moduledoc """
  Bridges daemon-owned usage-aggregate changes (DASH-024/030) into the protected
  financial-data facade (DASH-021).

  When the usage projection advances, authorized dashboard connections must be
  told to refresh. This worker observes the value-free `usage-aggregate:changed`
  signal and asks `AiurWeb.FinancialData` to broadcast a payload-free `:updated`
  notification to each currently-authorized connection. It carries no financial
  value and makes no authorization decision: authorization and payload-free
  delivery remain entirely owned by the facade.
  """

  use GenServer

  alias Aiur.UsageAggregate
  alias AiurWeb.FinancialData

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    subscribe_fun = Keyword.get(opts, :subscribe_fun, &UsageAggregate.subscribe/0)
    broadcast_fun = Keyword.get(opts, :broadcast_fun, &FinancialData.broadcast_update/0)
    _ = safe_subscribe(subscribe_fun)
    {:ok, %{broadcast_fun: broadcast_fun}}
  end

  @impl true
  def handle_info({:usage_aggregate_changed, _payload}, state) do
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
