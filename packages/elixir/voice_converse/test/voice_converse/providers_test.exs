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

defmodule VoiceConverse.ProvidersTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Config, Providers}
  alias VoiceConverse.Testing.{FakeBriefingSource, StaticCredentials}

  @cascade %{stt: [:browser_stt], llm: "anthropic:claude", tts: [:elevenlabs_tts]}

  setup do
    StaticCredentials.put(%{}, observer: self())
    on_exit(fn -> StaticCredentials.put(%{}) end)
    :ok
  end

  test "falls through to the next option on a missing key" do
    config = config(%{elevenlabs: "elevenlabs-secret"}, preference: [:openai_live, :elevenlabs_agents, :cascade])

    assert {:ok, %{id: :elevenlabs_agents}, skipped: [{:openai_live, {:missing_credential, :openai}}]} =
             Providers.resolve(config)
  end

  test "refuse policy stops at the first missing key" do
    config = config(%{}, preference: [:openai_live, :elevenlabs_agents], on_missing_credential: :refuse)

    assert {:error, :no_usable_option, [{:openai_live, {:missing_credential, :openai}}]} =
             Providers.resolve(config)
  end

  test "skips a ready provider refused by the privacy policy" do
    config =
      config(
        %{openai: "openai-secret", elevenlabs: "elevenlabs-secret"},
        preference: [:openai_live, :elevenlabs_agents],
        privacy: %{provider_allowlist: [:elevenlabs_agents]}
      )

    assert {:ok, %{id: :elevenlabs_agents},
            skipped: [{:openai_live, {:policy_refused, %{reason: :provider_not_allowed}}}]} =
             Providers.resolve(config)
  end

  test "refuse policy reports no usable option when every ready provider is refused" do
    config =
      config(
        %{openai: "openai-secret", elevenlabs: "elevenlabs-secret"},
        preference: [:openai_live, :elevenlabs_agents],
        on_missing_credential: :refuse,
        privacy: %{provider_allowlist: []}
      )

    assert {:error, :no_usable_option,
            [
              {:openai_live, {:policy_refused, %{reason: :provider_not_allowed}}},
              {:elevenlabs_agents, {:policy_refused, %{reason: :provider_not_allowed}}}
            ]} = Providers.resolve(config)
  end

  test "text mode excludes speech-only providers" do
    config = config(%{elevenlabs: "elevenlabs-secret"}, preference: [:openai_live, :elevenlabs_agents], mode: :text)

    assert {:ok, %{id: :elevenlabs_agents, modes: modes}, skipped: [{:openai_live, {:mode_unsupported, :text}}]} =
             Providers.resolve(config)

    assert :text in modes
  end

  test "options never contain a secret" do
    secret = "sentinel-provider-secret"
    config = config(%{elevenlabs: secret}, preference: [:elevenlabs_agents])

    assert options = Providers.options(config)
    refute inspect(options) =~ secret
  end

  test "text_only policy falls back to text_only" do
    config = config(%{anthropic: "anthropic-secret"}, preference: [:openai_live], on_missing_credential: :text_only)

    assert {:ok, %{id: :text_only}, skipped: [{:openai_live, {:missing_credential, :openai}}]} =
             Providers.resolve(config)

    missing_key_config = config(%{}, preference: [:openai_live], on_missing_credential: :text_only)

    assert {:error, :no_usable_option, skipped} = Providers.resolve(missing_key_config)
    assert {:text_only, {:missing_credential, :anthropic}} in skipped
  end

  test "unknown preference id is skipped" do
    config = config(%{elevenlabs: "elevenlabs-secret"}, preference: [:bogus, :elevenlabs_agents])

    assert {:ok, %{id: :elevenlabs_agents}, skipped: [{:bogus, :unknown_option}]} = Providers.resolve(config)
  end

  test "cascade needs follow the configured parts" do
    config = config(%{}, preference: [:cascade])
    [cascade] = Enum.filter(Providers.options(config), &(&1.id == :cascade))

    assert cascade.needs == [:anthropic, :elevenlabs]
    assert cascade.missing == [:anthropic, :elevenlabs]

    browser_only_config =
      config(%{}, preference: [:cascade], cascade: %{stt: [:browser_stt], llm: "anthropic:claude", tts: [:browser_tts]})

    [browser_only_cascade] = Enum.filter(Providers.options(browser_only_config), &(&1.id == :cascade))

    assert browser_only_cascade.needs == [:anthropic]
  end

  test "unloaded adapter is unsupported" do
    config = config(%{gemini: "gemini-secret"}, preference: [:gemini_live])
    [gemini_live] = Enum.filter(Providers.options(config), &(&1.id == :gemini_live))

    assert %{status: :unsupported, reason: :adapter_missing} = gemini_live
    assert {:error, :no_usable_option, [{:gemini_live, :adapter_missing}]} = Providers.resolve(config)
  end

  test "loaded adapters cannot change their registered identity or credentials" do
    [openai_live] = Enum.filter(Providers.options(config(%{}, preference: [:openai_live])), &(&1.id == :openai_live))

    assert %{family: :speech_to_speech, needs: [:openai], status: :needs_credential} = openai_live
  end

  test "options list every registered option with an unavailable reason" do
    options = Providers.options(config(%{}, []))

    assert Enum.map(options, & &1.id) == [
             :openai_live,
             :openai_realtime,
             :gemini_live,
             :elevenlabs_agents,
             :cascade,
             :text_only,
             :codex_realtime
           ]

    assert %{status: :unsupported, reason: :feature_unavailable} = Enum.find(options, &(&1.id == :codex_realtime))
    assert Providers.default_preference() == [:elevenlabs_agents, :openai_live, :gemini_live, :cascade]
  end

  test "probe is the only credential purpose" do
    config = config(%{elevenlabs: "elevenlabs-secret"}, preference: [:elevenlabs_agents])

    assert {:ok, %{id: :elevenlabs_agents}, skipped: []} = Providers.resolve(config)
    assert_receive {StaticCredentials, :fetch, :elevenlabs, :probe}

    assert Providers.options(config)
    assert_receive {StaticCredentials, :fetch, :openai, :probe}
    assert_receive {StaticCredentials, :fetch, :elevenlabs, :probe}
    assert_receive {StaticCredentials, :fetch, :anthropic, :probe}
    assert_receive {StaticCredentials, :fetch, :elevenlabs, :probe}
    assert_receive {StaticCredentials, :fetch, :anthropic, :probe}
    refute_receive {StaticCredentials, :fetch, _provider, :connect}
    refute_receive {StaticCredentials, :fetch, _provider, :provision}
    refute_receive {StaticCredentials, :fetch, _provider, :delete}
    refute_receive {StaticCredentials, :fetch, _provider, :render}
  end

  test "text_only policy retries text_only when it was in the preference" do
    config = config(%{anthropic: "anthropic-secret"}, preference: [:text_only], on_missing_credential: :text_only)

    assert {:ok, %{id: :text_only}, skipped: []} = Providers.resolve(config)
  end

  defp config(secrets, overrides) do
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
