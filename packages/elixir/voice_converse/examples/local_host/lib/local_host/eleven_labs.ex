defmodule LocalHost.ElevenLabs do
  @moduledoc "Host supplies the configured ElevenLabs agent id."
  alias VoiceConverse.Providers.ElevenLabsAgents, as: Provider
  defdelegate descriptor(), to: Provider
  defdelegate capabilities(), to: Provider

  def open(spec) do
    spec
    |> Map.put(:agent_id, System.fetch_env!("VOICE_HOST_ELEVENLABS_AGENT_ID"))
    |> Provider.open()
  end

  defdelegate push_audio(ref, audio), to: Provider
  defdelegate send_context(ref, text), to: Provider
  defdelegate send_user_text(ref, text), to: Provider
  defdelegate tool_result(ref, id, result), to: Provider
  defdelegate close(ref), to: Provider
end
