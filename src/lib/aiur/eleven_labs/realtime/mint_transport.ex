defmodule Aiur.ElevenLabs.Realtime.MintTransport do
  @moduledoc """
  The `Aiur.ElevenLabs.Realtime.Transport` implementation over `Mint.WebSocket`.

  This is the only place in the voice path that touches a socket, and it is
  deliberately free of protocol decisions: it opens a connection, writes text
  frames, forwards decoded text frames to the session, and closes. Every rule
  about readiness, backlog, finality and flushing lives in
  `Aiur.ElevenLabs.Realtime`, where it can be tested without a network.
  """

  @behaviour Aiur.ElevenLabs.Realtime.Transport

  alias Aiur.ElevenLabs.Realtime.MintSocket

  @impl true
  def connect(url, headers) do
    MintSocket.start(self(), url, headers)
  end

  @impl true
  def send_text(socket, text) do
    case MintSocket.send_text(socket, text) do
      :ok -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def close(socket), do: MintSocket.close(socket)
end
