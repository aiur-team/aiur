defmodule VoiceConverse.Provider.ElevenLabsAgents.Transport do
  @moduledoc false

  @callback connect(String.t(), [{String.t(), String.t()}]) :: {:ok, term()} | {:error, term()}
  @callback send_text(term(), String.t()) :: {:ok, term()} | {:error, term()}
  @callback close(term()) :: :ok
end

defmodule VoiceConverse.Provider.ElevenLabsAgents.MintTransport do
  @moduledoc false
  @behaviour VoiceConverse.Provider.ElevenLabsAgents.Transport

  alias VoiceConverse.Provider.ElevenLabsAgents.MintSocket

  @impl true
  def connect(url, headers), do: MintSocket.start(self(), url, headers)

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
