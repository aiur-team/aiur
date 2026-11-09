defmodule VoiceConverse.Provider.OpenAIRealtime.Transport do
  @moduledoc false
  alias VoiceConverse.Provider.ElevenLabsAgents.MintSocket

  @spec connect(String.t(), [{String.t(), String.t()}]) :: {:ok, pid()} | {:error, term()}
  def connect(url, headers), do: MintSocket.start(self(), url, headers, message_tag: :openai_realtime_transport)

  @spec send_text(pid(), String.t()) :: {:ok, pid()} | {:error, term()}
  def send_text(socket, text) do
    case MintSocket.send_text(socket, text) do
      :ok -> {:ok, socket}
      error -> error
    end
  end

  @spec close(pid()) :: :ok
  defdelegate close(socket), to: MintSocket
end
