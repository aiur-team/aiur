defmodule AiurWeb.DashboardLive.ProviderMeters do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias AiurWeb.EndpointConfig
  alias AiurWeb.FinancialDataAccess
  alias AiurWeb.OperatorControlCenter.CodexHeadroomPresenter
  alias AiurWeb.OperatorControlCenter.ProviderMeterSource
  alias AiurWeb.OperatorControlCenter.ProviderMetersPresenter

  @provider_meters_flush_ms 250

  # Provider meter cards read protected snapshots only through the DASH-021
  # facade. An authorized connection fetches once on mount and subscribes to
  # payload-free updates; a locked connection never obtains a context, never
  # queries, and never subscribes, so its card renders the content-free locked
  # state.
  @doc false
  @spec assign_initial_provider_meters(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def assign_initial_provider_meters(socket, connected) do
    capability = financial_data_capability(socket.assigns)

    snapshots =
      if connected and authorized?(capability) do
        context = FinancialDataAccess.context(socket)
        _subscription = subscribe_provider_meters(context)
        load_provider_meters(context)
      else
        %{}
      end

    socket
    |> assign(:provider_meter_snapshots, snapshots)
    |> assign(:provider_meters_pending_message, nil)
    |> assign(:provider_meters_flush_scheduled?, false)
    |> apply_provider_meters()
  end

  # Coalesce bursts of payload-free facade updates: schedule one flush per
  # debounce window so protected re-reads and screen-reader announcements stay
  # bounded and isolated from the render loop.
  @doc false
  @spec schedule_provider_meters_reload(Phoenix.LiveView.Socket.t(), term()) :: term()
  def schedule_provider_meters_reload(socket, message) do
    socket = assign(socket, :provider_meters_pending_message, message)

    if socket.assigns.provider_meters_flush_scheduled? do
      socket
    else
      schedule_provider_meters_flush()
      assign(socket, :provider_meters_flush_scheduled?, true)
    end
  end

  @doc false
  @spec flush_provider_meters(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def flush_provider_meters(socket) do
    socket = assign(socket, :provider_meters_flush_scheduled?, false)
    capability = financial_data_capability(socket.assigns)
    message = socket.assigns.provider_meters_pending_message

    if authorized?(capability) and not is_nil(message) do
      context = FinancialDataAccess.context(socket)
      snapshots = reload_provider_meters(context, message)

      socket
      |> assign(:provider_meter_snapshots, snapshots)
      |> assign(:provider_meters_pending_message, nil)
      |> apply_provider_meters()
    else
      socket
    end
  end

  defp apply_provider_meters(socket) do
    capability = financial_data_capability(socket.assigns)

    view = CodexHeadroomPresenter.provider_meters_view(capability, socket.assigns.provider_meter_snapshots)

    socket
    |> assign(:provider_meters_view, view)
    |> assign(:provider_meters_announcement, ProviderMetersPresenter.announcement(view))
  end

  defp subscribe_provider_meters(context), do: provider_meter_source().subscribe(context)
  defp load_provider_meters(context), do: provider_meter_source().load(context)
  defp reload_provider_meters(context, message), do: provider_meter_source().reload(context, message)

  defp provider_meter_source do
    case EndpointConfig.get(:provider_meter_source) do
      module when is_atom(module) and not is_nil(module) -> module
      _other -> ProviderMeterSource
    end
  end

  defp schedule_provider_meters_flush do
    case EndpointConfig.get(:provider_meters_flush_timer) do
      timer when is_function(timer, 3) -> timer.(self(), :flush_provider_meters, @provider_meters_flush_ms)
      _other -> Process.send_after(self(), :flush_provider_meters, @provider_meters_flush_ms)
    end
  end

  @doc false
  @spec financial_data_capability(term()) :: term()
  def financial_data_capability(assigns), do: Map.get(assigns, :financial_data_capability) || FinancialDataAccess.locked_capability()

  defp authorized?(%{state: :authorized}), do: true
  defp authorized?(_capability), do: false
end
