defmodule Aiur.VoiceConversation.ExecutorTranscript do
  @moduledoc "Resolves the registered live Executor before reading its harness-owned transcript."

  @spec read(pos_integer()) :: {:ok, map()} | {:error, :unavailable}
  def read(n), do: read_session(Aiur.Executor.HarnessSession.current(), n)

  @spec read_session(map(), pos_integer()) :: {:ok, map()} | {:error, :unavailable}
  def read_session(session, n), do: Aiur.CodingAgent.read_native_transcript(session, n)
end
