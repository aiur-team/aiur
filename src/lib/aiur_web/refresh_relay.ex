defmodule AiurWeb.RefreshRelay do
  @moduledoc "Coalesces snapshot notifications before they enter a LiveView mailbox."
  use GenServer
  alias Phoenix.LiveView
  alias Phoenix.LiveView.Socket
  @interval_ms 500

  @spec mount(Socket.t(), (-> term()), [atom()]) :: Socket.t()
  def mount(socket, subscribe, events) do
    if LiveView.connected?(socket) do
      {:ok, relay} = GenServer.start_link(__MODULE__, {self(), subscribe, events})

      LiveView.attach_hook(socket, relay, :handle_info, &handle_message(&1, &2, relay))
    else
      socket
    end
  end

  defp handle_message({:coalesced_refresh, relay, messages}, socket, relay) do
    socket =
      Enum.reduce(messages, socket, fn message, socket ->
        {:noreply, socket} = socket.view.handle_info(message, socket)
        socket
      end)

    # An acknowledged batch permits one more delivery, even if the next render is slow.
    GenServer.cast(relay, :ack)
    {:halt, socket}
  end

  defp handle_message(_message, socket, _relay), do: {:cont, socket}

  @impl true
  def init({owner, subscribe, events}) do
    monitor = Process.monitor(owner)
    subscribe.()
    {:ok, %{owner: owner, monitor: monitor, events: events, pending: %{}, timer: nil, waiting?: false}}
  end

  @impl true
  def handle_cast(:ack, state), do: {:noreply, schedule(%{state | waiting?: false})}

  @impl true
  def handle_info(:flush, state) do
    send(state.owner, {:coalesced_refresh, self(), Map.values(state.pending)})
    {:noreply, %{state | pending: %{}, timer: nil, waiting?: true}}
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, %{monitor: monitor, owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(message, state) do
    kind = if is_tuple(message) and tuple_size(message) > 0, do: elem(message, 0), else: message

    if kind in state.events do
      {:noreply, schedule(%{state | pending: Map.put(state.pending, kind, message)})}
    else
      {:noreply, state}
    end
  end

  defp schedule(%{timer: nil, waiting?: false, pending: pending} = state) when map_size(pending) > 0,
    do: %{state | timer: Process.send_after(self(), :flush, @interval_ms)}

  defp schedule(state), do: state
end
