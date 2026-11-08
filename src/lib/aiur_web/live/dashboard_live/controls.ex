defmodule AiurWeb.DashboardLive.Controls do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]
  alias AiurWeb.DashboardLive.Commands
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.PauseState

  @doc false
  @spec toggle_global_pause(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_global_pause(socket) do
    socket
    |> assign(:globally_paused, global_pause_state(socket.assigns.payload))
    |> PauseState.toggle()
    |> Commands.reload_after_action()
  end

  @doc false
  @spec global_pause_state(map()) :: boolean() | :loading | nil
  def global_pause_state(%{fleet: %{error: _error}}) do
    PauseState.pause_state(capacity_orchestrator())
  rescue
    _endpoint_unavailable -> nil
  catch
    :exit, _reason -> nil
  end

  def global_pause_state(%{fleet: %{globally_paused: paused}}) when is_boolean(paused), do: paused
  def global_pause_state(_payload), do: nil

  @spec capacity_orchestrator() :: GenServer.server()
  def capacity_orchestrator, do: EndpointConfig.get(:orchestrator) || Aiur.Orchestrator
end
