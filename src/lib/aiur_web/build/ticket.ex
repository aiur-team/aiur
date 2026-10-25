defmodule AiurWeb.Build.Ticket do
  @moduledoc "Bounded, read-only modal reads over the complete ticket index."
  import Phoenix.Component, only: [assign: 3]
  alias AiurWeb.Build.{Controls, DataSource, Payload, Read, URLState}

  @spec open(Phoenix.LiveView.Socket.t(), map()) :: {:reply, map(), Phoenix.LiveView.Socket.t()}
  def open(socket, %{"id" => raw} = params) when is_binary(raw) do
    case URLState.parse(%{"ticket" => raw}).ticket do
      nil ->
        {:reply, Payload.error(:invalid_params), socket}

      id ->
        socket = assign(socket, :open_ticket, id)
        reply = if params["loaded"] == true, do: envelope(socket, nil), else: read(socket, id)
        {:reply, reply, socket}
    end
  end

  def open(socket, _params), do: {:reply, Payload.error(:invalid_params), socket}

  defp read(socket, id) do
    case Read.safe_read(fn -> DataSource.call(socket.assigns.build_source, :ticket, [id, Read.source_opts(socket)]) end) do
      {:ok, row} -> validated(socket, row)
      {:error, :not_found} -> Payload.error(:not_found)
      {:error, _reason} -> Payload.error(:unavailable)
    end
  end

  defp validated(socket, row) do
    message = envelope(socket, row)
    if Payload.validate(message) == :ok, do: message, else: Payload.error(:unavailable)
  end

  defp envelope(socket, row) do
    control = Controls.read_body(socket, socket.assigns.open_ticket)
    Payload.ticket(row, socket.assigns.build_epoch, socket.assigns.build_generation) |> Map.merge(Map.take(control, ~w(control chat by_you_at)))
  end
end
