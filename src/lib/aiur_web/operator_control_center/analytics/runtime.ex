defmodule AiurWeb.OperatorControlCenter.Analytics.Runtime do
  @moduledoc "Loads Analytics outside the HTTP request and LiveView event loop."

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  alias Aiur.PollCadence
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter
  alias AiurWeb.OperatorControlCenter.{AwaitingCommands, DashboardShell}

  @load_timeout_ms 15_000
  @load_tick_ms 1_000

  @spec load(Phoenix.LiveView.Socket.t(), keyword(), (-> map())) :: Phoenix.LiveView.Socket.t()
  def load(socket, scope_opts, rtk_loader) do
    token = make_ref()
    started_at = System.monotonic_time(:millisecond)
    timeout_ms = Application.get_env(:aiur, :analytics_load_timeout_ms, @load_timeout_ms)
    Process.send_after(self(), {:analytics_load_tick, token}, @load_tick_ms)
    Process.send_after(self(), {:analytics_load_timeout, token}, timeout_ms)

    opts =
      [
        range: socket.assigns.range,
        session: if(socket.assigns.range == :full, do: :cross, else: :current),
        telemetry_file: Application.get_env(:aiur, :analytics_telemetry_file),
        orchestrator: AiurWeb.EndpointConfig.get(:orchestrator) || Aiur.Orchestrator,
        snapshot_timeout_ms: PollCadence.snapshot_tolerance_ms(AiurWeb.EndpointConfig.get(:snapshot_timeout_ms) || 15_000)
      ] ++ scope_opts

    socket
    |> assign(
      model: nil,
      chart_model: nil,
      time_domain: nil,
      provider_spend: %{state: :loading},
      selected: MapSet.new(),
      source: nil,
      unavailable: :loading,
      rtk: %{state: :absent, title: "Loading compression data", message: "Analytics loading is in progress."},
      now: DateTime.utc_now()
    )
    |> assign(analytics_load_token: token, analytics_load_started_at: started_at, analytics_load_elapsed_seconds: 0, analytics_load_timeout_seconds: timeout_ms / 1_000)
    |> start_async(:analytics_model, fn -> {Presenter.load(opts), rtk_loader.()} end)
  end

  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:analytics_load_tick, token}, %{assigns: %{unavailable: :loading, analytics_load_token: token}} = socket) do
    elapsed = div(System.monotonic_time(:millisecond) - socket.assigns.analytics_load_started_at, 1_000)
    Process.send_after(self(), {:analytics_load_tick, token}, @load_tick_ms)
    {:noreply, assign(socket, :analytics_load_elapsed_seconds, elapsed)}
  end

  def handle_info({:analytics_load_timeout, token}, %{assigns: %{unavailable: :loading, analytics_load_token: token}} = socket) do
    {:noreply, socket |> Phoenix.LiveView.cancel_async(:analytics_model) |> assign(:unavailable, :timeout)}
  end

  def handle_info({:decision_changed, _decision_id, _version}, socket), do: {:noreply, AwaitingCommands.refresh(socket)}
  def handle_info(:awaiting_commands_tick, socket), do: {:noreply, AwaitingCommands.tick(socket)}
  def handle_info(message, socket), do: DashboardShell.handle_info(message, socket)
end
