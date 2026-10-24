defmodule VoiceConverse.Providers.ElevenLabsAgents do
  def descriptor do
    %{
      id: :elevenlabs_agents,
      family: :hosted_agent,
      label: "ElevenLabs Agents",
      modes: [:voice, :text],
      needs: [:elevenlabs],
      privacy: %{audio_stored_by_provider: true, deletable?: true},
      price_hint: "provider-priced"
    }
  end
end

defmodule VoiceConverse.Providers.OpenAILive do
  def descriptor do
    %{
      id: :wrong_id,
      family: :hosted_agent,
      label: "OpenAI Live",
      modes: [:voice],
      needs: [:elevenlabs],
      privacy: %{audio_stored_by_provider: true, deletable?: false},
      price_hint: "provider-priced"
    }
  end
end

defmodule VoiceConverse.Testing.ProviderTestSupport do
  alias VoiceConverse.Config
  alias VoiceConverse.Testing.{FakeBriefingSource, StaticCredentials}

  @cascade %{stt: [:browser_stt], llm: "anthropic:claude", tts: [:elevenlabs_tts]}

  def config(secrets, overrides) do
    StaticCredentials.put(secrets, observer: self())
    provider_overrides = Keyword.drop(overrides, [:privacy])

    providers =
      Map.merge(
        %{
          preference: [:elevenlabs_agents, :openai_live, :gemini_live, :cascade],
          mode: :voice,
          cascade: @cascade,
          on_missing_credential: :next
        },
        Map.new(provider_overrides)
      )

    {:ok, config} =
      Config.new(
        transcript: :none,
        credentials: StaticCredentials,
        briefing_source: FakeBriefingSource,
        providers: providers,
        privacy: Keyword.get(overrides, :privacy, %{})
      )

    config
  end
end
