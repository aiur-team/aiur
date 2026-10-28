defmodule AiurWeb.StreamdeckLive.Input do
  @moduledoc "Route device-shaped input to the emulator's existing focused controls."
  alias AiurWeb.StreamdeckLive
  alias AiurWeb.StreamdeckLive.Settings

  @spec handle(map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle(raw, socket) do
    if Settings.handles?(raw, socket), do: Settings.input(raw, socket), else: route(raw, socket)
  end

  defp route(%{"kind" => "dial", "index" => index, "action" => "turn", "delta" => delta}, socket)
       when index in 0..3 and is_integer(delta) and delta in -32..32 do
    case {socket.assigns.sd_mode, index} do
      {:logs, 0} ->
        StreamdeckLive.handle_event(
          "logs-scroll",
          %{"axis" => "transcript", "delta" => delta},
          socket
        )

      {:logs, 3} ->
        StreamdeckLive.handle_event(
          "logs-scroll",
          %{"axis" => "events", "delta" => delta},
          socket
        )

      {:grid, 3} ->
        StreamdeckLive.handle_event(
          "grid-page",
          %{"page" => socket.assigns.grid_page + delta},
          socket
        )

      _ ->
        StreamdeckLive.reduce_input(%{"kind" => "dial", "index" => index, "action" => "turn", "delta" => delta}, socket)
    end
  end

  defp route(%{"kind" => "dial", "index" => 0, "action" => "press"}, socket),
    do: StreamdeckLive.handle_event("dial-press", %{"index" => 0, "action" => "back"}, socket)

  defp route(
         %{"kind" => "dial", "index" => 3, "action" => "press"},
         %{assigns: %{sd_mode: :grid}} = socket
       ),
       do: StreamdeckLive.handle_event("grid-page", %{"action" => "cycle"}, socket)

  defp route(%{"kind" => "dial", "index" => 3, "action" => "press"}, socket),
    do:
      StreamdeckLive.handle_event(
        "dial-press",
        %{"index" => 3, "action" => "cycle-window"},
        socket
      )

  defp route(raw, socket), do: StreamdeckLive.reduce_input(raw, socket)
end
