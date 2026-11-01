defmodule AiurWeb.Streamdeck.UsageUpdates do
  @moduledoc false
  import Phoenix.Socket, only: [assign: 3]
  alias AiurWeb.Streamdeck.Deck.Meters
  alias AiurWeb.StreamdeckFleetUpdates

  # Reuse the initial snapshot, then refresh on fleet flushes no faster than
  # the slower Build API tick (ElevenLabs, 60s).
  @spec refresh(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def refresh(socket) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns[:deck_usage_refreshed_at]

    cond do
      is_nil(last) -> assign(socket, :deck_usage_refreshed_at, now)
      now - last < 60_000 -> socket
      true -> socket |> assign(:deck_usage, Meters.read()) |> assign(:deck_usage_refreshed_at, now)
    end
  end

  @spec schedule(Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def schedule(%{assigns: %{usage_flush: nil}} = socket) do
    token = make_ref()
    Process.send_after(self(), {:flush_usage, token}, 250)
    {:noreply, assign(socket, :usage_flush, token)}
  end

  def schedule(socket), do: {:noreply, socket}

  @spec flush(Phoenix.Socket.t(), reference()) :: {:noreply, Phoenix.Socket.t()}
  def flush(%{assigns: %{usage_flush: token}} = socket, token) when is_reference(token) do
    usage = Meters.read()
    Phoenix.Channel.push(socket, "usage", usage)
    socket |> assign(:deck_usage, usage) |> assign(:deck_usage_refreshed_at, System.monotonic_time(:millisecond)) |> assign(:usage_flush, nil) |> StreamdeckFleetUpdates.schedule()
  end

  def flush(socket, _old_token), do: {:noreply, socket}
end
