defmodule Aiur.Config.VoiceConversationPaths do
  @moduledoc false

  alias Aiur.Config.Paths

  @spec voice_conversation_state_dir() :: {:ok, Path.t()} | {:error, atom()}
  def voice_conversation_state_dir do
    with {:ok, root} <- Paths.conversation_state_dir(), do: {:ok, Path.join(root, "voice")}
  end
end
