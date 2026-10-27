defmodule VoiceConverse.ProvidersPolicyTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.Providers
  alias VoiceConverse.Testing.StaticCredentials
  import VoiceConverse.Testing.ProviderTestSupport, only: [config: 2]

  setup do
    StaticCredentials.put(%{}, observer: self())
    on_exit(fn -> StaticCredentials.put(%{}) end)
    :ok
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

  test "skips a provider that does not meet required privacy options" do
    config =
      config(
        %{openai: "openai-secret", elevenlabs: "elevenlabs-secret"},
        preference: [:openai_live, :elevenlabs_agents],
        privacy: %{
          provider_allowlist: [:openai_live, :elevenlabs_agents],
          required_provider_options: %{openai_live: %{audio_stored_by_provider: false}}
        }
      )

    assert {:ok, %{id: :elevenlabs_agents},
            skipped: [{:openai_live, {:policy_refused, %{reason: :required_option_unmet}}}]} =
             Providers.resolve(config)
  end

  test "text_only fallback respects the privacy policy" do
    config =
      config(
        %{anthropic: "anthropic-secret"},
        preference: [:openai_live],
        on_missing_credential: :text_only,
        privacy: %{provider_allowlist: [:openai_live]}
      )

    assert {:error, :no_usable_option,
            [
              {:openai_live, {:missing_credential, :openai}},
              {:text_only, {:policy_refused, %{reason: :provider_not_allowed}}}
            ]} = Providers.resolve(config)
  end
end
