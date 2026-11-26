defmodule Aiur.VoiceConversation.ExecutorTranscript do
  @moduledoc "Resolves the registered live Executor before reading its harness-owned transcript."

  alias Aiur.CodingAgent
  alias Aiur.Executor.HarnessSession

  @spec read(pos_integer()) :: {:ok, map()} | {:error, :unavailable}
  def read(n), do: read_session(HarnessSession.current(), n)

  @spec read_session(map(), pos_integer()) :: {:ok, map()} | {:error, :unavailable}
  def read_session(session, n), do: CodingAgent.read_native_transcript(session, n)
end
