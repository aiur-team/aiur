defmodule VoiceConverse.Providers.OpenAIRealtime do
  @moduledoc "OpenAI Realtime provider using the shared voice session port."
  @behaviour VoiceConverse.Provider

  @impl true
  defdelegate descriptor(), to: VoiceConverse.Provider.OpenAIRealtime
  @impl true
  defdelegate capabilities(), to: VoiceConverse.Provider.OpenAIRealtime
  @impl true
  defdelegate open(spec), to: VoiceConverse.Provider.OpenAIRealtime
  @impl true
  defdelegate push_audio(ref, audio), to: VoiceConverse.Provider.OpenAIRealtime
  @impl true
  defdelegate send_context(ref, text), to: VoiceConverse.Provider.OpenAIRealtime
  @impl true
  defdelegate send_user_text(ref, text), to: VoiceConverse.Provider.OpenAIRealtime
  @impl true
  defdelegate tool_result(ref, id, result), to: VoiceConverse.Provider.OpenAIRealtime
  @impl true
  defdelegate close(ref), to: VoiceConverse.Provider.OpenAIRealtime
end
