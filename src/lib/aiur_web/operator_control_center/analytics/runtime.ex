defmodule AiurWeb.OperatorControlCenter.Analytics.Runtime do
  @moduledoc "Loads Analytics outside the HTTP request and LiveView event loop."

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [start_async: 3]

  alias Aiur.PollCadence
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  @spec load(Phoenix.LiveView.Socket.t(), keyword(), (-> map())) :: Phoenix.LiveView.Socket.t()
  def load(socket, scope_opts, rtk_loader) do
    opts =
      [
        range: socket.assigns.range,
        session: if(socket.assigns.range == :full, do: :cross, else: :current),
        telemetry_file: Application.get_env(:aiur, :analytics_telemetry_file),
        orchestrator: AiurWeb.Endpoint.config(:orchestrator) || Aiur.Orchestrator,
        snapshot_timeout_ms: PollCadence.snapshot_tolerance_ms(AiurWeb.Endpoint.config(:snapshot_timeout_ms) || 15_000)
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
    |> start_async(:analytics_model, fn -> {Presenter.load(opts), rtk_loader.()} end)
  end
end
