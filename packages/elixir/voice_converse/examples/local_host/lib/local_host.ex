defmodule LocalHost do
  @moduledoc "Standalone example settings, independent of any parent application."
  def path(file), do: Path.join(Application.fetch_env!(:local_host, :root), file)

  def voice_config do
    fake? = Application.fetch_env!(:local_host, :provider) == "fake"
    provider = provider(Application.fetch_env!(:local_host, :provider))

    VoiceConverse.Config.new(
      name: LocalHost.Voice,
      transcript_root: path("transcripts"),
      credentials: LocalHost.Credentials,
      token_issuer: VoiceConverse.TokenIssuer.Hmac,
      briefing_source: LocalHost.BriefingSource,
      agent_channel: LocalHost.AgentChannel,
      provider: provider,
      roles: [
        %{
          id: "executor",
          title: "Local assistant",
          prompt:
            "Answer from the briefing. Use propose_instruction for changes; wait for client confirmation."
        }
      ],
      llm: Application.fetch_env!(:local_host, :llm),
      cloud_disclosure_accepted:
        fake? or Application.fetch_env!(:local_host, :cloud_disclosure_accepted)
    )
  end

  defp provider("fake"),
    do:
      {VoiceConverse.Testing.FakeProvider,
       [script: [%VoiceConverse.Events.ProviderConversationId{id: "local-fake"}]]}

  defp provider("openai"), do: VoiceConverse.Providers.OpenAIRealtime
  defp provider("elevenlabs"), do: LocalHost.ElevenLabs
  defp provider(_name), do: raise(ArgumentError, "provider must be fake, openai, or elevenlabs")
end
