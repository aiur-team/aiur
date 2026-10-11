defmodule AiurWeb.OperatorControlCenter.PauseState do
  @moduledoc false

  alias Phoenix.LiveView.Socket

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias Aiur.{AgentPubSub, Orchestrator}
  alias Aiur.Orchestrator.{GlobalPause, SnapshotStore}
  alias AiurWeb.Endpoint

  @spec mount(Socket.t()) :: Socket.t()
  def mount(socket) do
    if connected?(socket) do
      AgentPubSub.subscribe_running()
    end

    socket
    |> assign(:globally_paused, pause_state())
    |> assign(:writable, Endpoint.config(:dashboard_writable) == true)
    |> assign(:global_pause_error, nil)
  end

  @spec refresh(Socket.t()) :: Socket.t()
  def refresh(socket), do: assign(socket, :globally_paused, pause_state())

  @spec toggle(Socket.t()) :: Socket.t()
  def toggle(socket) do
    if Endpoint.config(:dashboard_writable) == true and is_boolean(socket.assigns.globally_paused) do
      do_toggle(socket)
    else
      socket
    end
  end

  @spec shell_state(boolean() | nil, boolean(), String.t() | nil) :: map()
  def shell_state(paused, writable, error),
    do: %{globally_paused: paused, writable: writable, global_pause_error: error}

  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_info({:running_changed, _summaries}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:fleet_changed, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @spec handle_event(term(), term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("toggle-global-pause", _params, socket), do: {:noreply, toggle(socket)}

  defp do_toggle(socket) do
    target = not socket.assigns.globally_paused

    case GlobalPause.set_global_pause(orchestrator(), target, "dashboard") do
      {:ok, _status} ->
        socket
        |> assign(:globally_paused, target)
        |> assign(:global_pause_error, nil)

      {:error, _reason} ->
        assign(socket, :global_pause_error, "Global pause could not be confirmed. Refresh the page before retrying.")
    end
  end

  defp pause_state do
    orchestrator = orchestrator()

    if orchestrator == Orchestrator do
      case SnapshotStore.read(orchestrator, 1_000) do
        {:current, %{globally_paused: paused}, _freshness} when is_boolean(paused) -> paused
        {:stale, _, _freshness} -> nil
        _unavailable -> live_pause_state(orchestrator)
      end
    else
      snapshot_pause_state(orchestrator)
    end
  end

  defp orchestrator, do: Endpoint.config(:orchestrator) || Orchestrator

  defp live_pause_state(orchestrator) do
    case GlobalPause.global_pause_status(orchestrator, 1_000) do
      {:ok, %{globally_paused: paused}} when is_boolean(paused) -> paused
      _unavailable -> nil
    end
  end

  defp snapshot_pause_state(orchestrator) do
    case SnapshotStore.read(orchestrator, 1_000) do
      {:current, %{globally_paused: paused}, _freshness} when is_boolean(paused) -> paused
      _unavailable -> nil
    end
  end
end
