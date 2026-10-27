defmodule AiurWeb.EventsSocket do
  @moduledoc false

  use Phoenix.Socket

  alias AiurWeb.EventsAuth

  channel("events:feed", AiurWeb.EventsChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case EventsAuth.verify_token(token) do
      {:ok, generation, expires_at_ms} ->
        {:ok,
         socket
         |> assign(:events_authenticated, true)
         |> assign(:events_generation, generation)
         |> assign(:events_expires_at_ms, expires_at_ms)}

      :error ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
