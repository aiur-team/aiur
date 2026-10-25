defmodule VoiceConverse.Providers.ElevenLabsAgents do
  @moduledoc false

  defdelegate descriptor(), to: VoiceConverse.Provider.ElevenLabsAgents
  defdelegate capabilities(), to: VoiceConverse.Provider.ElevenLabsAgents
  defdelegate open(spec), to: VoiceConverse.Provider.ElevenLabsAgents
  defdelegate push_audio(ref, base64_pcm), to: VoiceConverse.Provider.ElevenLabsAgents
  defdelegate send_context(ref, text), to: VoiceConverse.Provider.ElevenLabsAgents
  defdelegate send_user_text(ref, text), to: VoiceConverse.Provider.ElevenLabsAgents
  defdelegate close(ref), to: VoiceConverse.Provider.ElevenLabsAgents
end
