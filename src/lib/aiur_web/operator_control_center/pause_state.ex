defmodule AiurWeb.OperatorControlCenter.PauseState do
  @moduledoc false

  alias Phoenix.LiveView.Socket

  import Phoenix.Component, only: [assign: 3]
  alias Aiur.{AgentPubSub, Orchestrator}
  alias Aiur.Orchestrator.{GlobalPause, SnapshotStore}
  alias AiurWeb.{Endpoint, RefreshRelay}

  @spec mount(Socket.t()) :: Socket.t()
  def mount(socket) do
    socket
    |> RefreshRelay.mount(
      &AgentPubSub.subscribe_fleet_invalidation/0,
      [:fleet_changed]
    )
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

  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_info({:running_changed, _summaries}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:fleet_changed, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp do_toggle(socket) do
    target = not socket.assigns.globally_paused

    case GlobalPause.set_global_pause(orchestrator(), target, "dashboard") do
      {:ok, _status} ->
        socket
        |> assign(:globally_paused, target)
        |> assign(:global_pause_error, nil)

      {:error, {:global_pause_persistence_failed, _reason}} ->
        assign(socket, :global_pause_error, "Global pause was not changed because its state could not be persisted. The daemon remains in its previous state; check the daemon log and retry.")

      {:error, reason} ->
        assign(socket, :global_pause_error, "Global pause could not be changed: #{inspect(reason)}")
    end
  end

  @spec pause_state(GenServer.server()) :: boolean() | nil
  def pause_state(orchestrator) do
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

  defp pause_state, do: pause_state(orchestrator())

  defp orchestrator, do: Endpoint.config(:orchestrator) || Orchestrator

  defp live_pause_state(orchestrator) do
    case GlobalPause.global_pause_status(orchestrator, 1_000) do
      {:ok, %{globally_paused: paused}} when is_boolean(paused) -> paused
      _unavailable -> nil
    end
  end

  defp snapshot_pause_state(orchestrator) do
    case SnapshotStore.read(orchestrator, 1_000) do
      {:current, %{globally_paused: paused}, _freshness} when is_boolean(paused) ->
        paused

      {:stale, _, _freshness} ->
        nil

      unavailable when unavailable in [:orchestrator_unavailable, :snapshot_unpublished] ->
        live_pause_state(orchestrator)

      _unavailable ->
        nil
    end
  end
end
