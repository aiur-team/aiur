defmodule Aiur.VoiceConversation.OpenAIProvider do
  @moduledoc "Supplies the shared Executor prompt and configured voice to OpenAI Realtime."
  @behaviour VoiceConverse.Provider
  alias VoiceConverse.Providers.OpenAIRealtime

  @impl true
  defdelegate descriptor(), to: OpenAIRealtime
  @impl true
  defdelegate capabilities(), to: OpenAIRealtime

  @impl true
  def open(spec) do
    voice = spec |> Map.get(:fake, []) |> Keyword.get(:voice_id)
    spec |> Map.put(:voice_id, voice) |> Map.put(:system_prompt, Aiur.VoiceConversation.Provider.prompt()) |> OpenAIRealtime.open()
  end

  @impl true
  defdelegate push_audio(ref, audio), to: OpenAIRealtime
  @impl true
  defdelegate send_context(ref, text), to: OpenAIRealtime
  @impl true
  defdelegate send_user_text(ref, text), to: OpenAIRealtime
  @impl true
  defdelegate tool_result(ref, id, result), to: OpenAIRealtime
  @impl true
  defdelegate close(ref), to: OpenAIRealtime
end
