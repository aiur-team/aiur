defmodule AiurWeb.OperatorControlCenter.PauseState do
  @moduledoc false

  alias Phoenix.LiveView.Socket

  import Phoenix.Component, only: [assign: 3]
  alias Aiur.{AgentPubSub, Orchestrator}
  alias Aiur.Orchestrator.{GlobalPause, SnapshotStore}
  alias AiurWeb.{EndpointConfig, RefreshRelay}

  @startup_loading_timeout_ms 600_000

  @spec mount(Socket.t()) :: Socket.t()
  def mount(socket) do
    socket
    |> RefreshRelay.mount(
      &AgentPubSub.subscribe_fleet_invalidation/0,
      [:fleet_changed]
    )
    |> assign(:globally_paused, pause_state())
    |> assign(:writable, EndpointConfig.get(:dashboard_writable) == true)
    |> assign(:global_pause_error, nil)
    |> schedule_startup_deadline()
  end

  @spec refresh(Socket.t()) :: Socket.t()
  def refresh(socket), do: socket |> assign(:globally_paused, pause_state()) |> schedule_startup_deadline()

  @spec toggle(Socket.t()) :: Socket.t()
  def toggle(socket) do
    cond do
      EndpointConfig.get(:dashboard_writable) != true -> assign(socket, :writable, false)
      is_boolean(socket.assigns.globally_paused) -> do_toggle(socket)
      true -> assign(socket, :global_pause_error, "Global pause state is unknown; refresh and retry.")
    end
  end

  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_info({:running_changed, _summaries}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:fleet_changed, socket), do: {:noreply, refresh(socket)}
  def handle_info(:pause_startup_deadline, %{assigns: %{globally_paused: :loading}} = socket), do: {:noreply, assign(socket, :globally_paused, nil) |> assign(:pause_loading_timer, nil)}
  def handle_info(:pause_startup_deadline, socket), do: {:noreply, socket}
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

  @spec pause_state(GenServer.server()) :: boolean() | :loading | nil
  def pause_state(orchestrator), do: pause_state(orchestrator, Aiur.Boot.elapsed_ms())

  @doc false
  @spec pause_state(GenServer.server(), non_neg_integer()) :: boolean() | :loading | nil
  def pause_state(orchestrator, startup_elapsed_ms) when is_integer(startup_elapsed_ms) and startup_elapsed_ms >= 0 do
    if orchestrator == Orchestrator do
      case SnapshotStore.read(orchestrator, 1_000) do
        {:current, %{globally_paused: paused}, _freshness} when is_boolean(paused) -> paused
        {:stale, %{globally_paused: paused}, _freshness} when is_boolean(paused) -> paused
        {:stale, _, _freshness} -> startup_pause_state(orchestrator, startup_elapsed_ms)
        :snapshot_unpublished -> loading_pause_state(orchestrator, startup_elapsed_ms)
        {:current, _snapshot, _freshness} -> startup_pause_state(orchestrator, startup_elapsed_ms)
        _unavailable -> nil
      end
    else
      snapshot_pause_state(orchestrator, startup_elapsed_ms)
    end
  end

  defp pause_state, do: pause_state(orchestrator())

  defp orchestrator, do: EndpointConfig.get(:orchestrator) || Orchestrator

  defp loading_pause_state(orchestrator, startup_elapsed_ms) do
    case GlobalPause.global_pause_status(orchestrator, 1_000) do
      {:ok, %{globally_paused: paused}} when is_boolean(paused) -> paused
      _unavailable -> startup_pause_state(orchestrator, startup_elapsed_ms)
    end
  end

  defp startup_pause_state(orchestrator, startup_elapsed_ms) do
    if live?(orchestrator) and startup_elapsed_ms < @startup_loading_timeout_ms, do: :loading, else: nil
  end

  defp live?(orchestrator) do
    case GenServer.whereis(orchestrator) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _missing -> false
    end
  catch
    :exit, _reason -> false
  end

  defp snapshot_pause_state(orchestrator, startup_elapsed_ms) do
    case SnapshotStore.read(orchestrator, 1_000) do
      {:current, %{globally_paused: paused}, _freshness} when is_boolean(paused) ->
        paused

      {:stale, %{globally_paused: paused}, _freshness} when is_boolean(paused) ->
        paused

      {:stale, _, _freshness} ->
        startup_pause_state(orchestrator, startup_elapsed_ms)

      :snapshot_unpublished ->
        loading_pause_state(orchestrator, startup_elapsed_ms)

      :orchestrator_unavailable ->
        nil

      _unavailable ->
        startup_pause_state(orchestrator, startup_elapsed_ms)
    end
  end

  defp schedule_startup_deadline(socket) do
    if timer = Map.get(socket.assigns, :pause_loading_timer), do: Process.cancel_timer(timer)

    if Phoenix.LiveView.connected?(socket) and socket.assigns.globally_paused == :loading do
      remaining_ms = max(@startup_loading_timeout_ms - Aiur.Boot.elapsed_ms(), 0)
      timer = Process.send_after(self(), :pause_startup_deadline, remaining_ms)
      assign(socket, :pause_loading_timer, timer)
    else
      assign(socket, :pause_loading_timer, nil)
    end
  end
end
