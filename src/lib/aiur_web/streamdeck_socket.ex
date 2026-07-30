defmodule AiurWeb.StreamdeckSocket do
  @moduledoc false

  use Phoenix.Socket

  alias AiurWeb.StreamdeckAuth

  channel("streamdeck:fleet", AiurWeb.StreamdeckChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case StreamdeckAuth.verify_token(token) do
      {:ok, generation, expires_at_ms} ->
        {:ok,
         socket
         |> assign(:streamdeck_authenticated, true)
         |> assign(:streamdeck_generation, generation)
         |> assign(:streamdeck_expires_at_ms, expires_at_ms)}

      :error ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
