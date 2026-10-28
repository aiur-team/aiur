defmodule VoiceConverse.NarrationPolicyTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Narration, ProviderPolicy}
  alias VoiceConverse.Testing.{FakeProvider, StaticCredentials}

  @allowed_host "speech.internal"
  @base_opts [provider: FakeProvider, credentials: {StaticCredentials, :fake}]

  setup do
    StaticCredentials.put(%{fake: "test-secret"})
    on_exit(fn -> StaticCredentials.put(%{}) end)
    :ok
  end

  test "requires the host privacy policy instead of silently rendering without one" do
    assert {:error, %{field: :privacy, reason: :missing}} = Narration.render("private narration", @base_opts)
  end

  test "refuses a narration provider outside the provider allowlist" do
    privacy = %{provider_allowlist: [:approved_provider]}

    assert {:error, %{reason: :provider_not_allowed, provider: :fake, allowed: [:approved_provider]}} =
             Narration.render("private narration", @base_opts ++ [privacy: privacy])
  end

  test "refuses an allowed provider missing a required no-logging option" do
    privacy = %{
      provider_allowlist: [:fake],
      required_provider_options: %{fake: %{store: false}}
    }

    assert {:error, %{reason: :required_option_unmet, provider: :fake, option: :store, actual: :missing}} =
             Narration.render("private narration", @base_opts ++ [privacy: privacy])
  end

  test "allows an OpenAI-compatible speech URL whose host is allowlisted" do
    # Compatibility guard: host enforcement must not reject a valid configured endpoint. The
    # refusal and missing-host cases below are the mutation guards for the new enforcement.
    privacy = %{provider_allowlist: [:fake], provider_host_allowlist: [@allowed_host]}

    assert {:ok, %{audio: audio}} =
             Narration.render(
               "private narration",
               @base_opts ++ [privacy: privacy, base_url: "https://#{@allowed_host}:8443/v1/audio/speech"]
             )

    assert byte_size(audio) > 0
  end

  test "refuses an OpenAI-compatible speech URL whose host is not allowlisted" do
    privacy = %{provider_allowlist: [:fake], provider_host_allowlist: [@allowed_host]}

    assert {:error,
            %{
              reason: :provider_host_not_allowed,
              provider: :fake,
              host: "speech.other.internal",
              allowed: [@allowed_host]
            }} =
             Narration.render(
               "private narration",
               @base_opts ++ [privacy: privacy, base_url: "https://speech.other.internal/v1/audio/speech"]
             )
  end

  test "fails closed when a host allowlist is set but no provider base URL is declared" do
    privacy = %{provider_allowlist: [:fake], provider_host_allowlist: [@allowed_host]}

    assert {:error, %{reason: :provider_host_missing, provider: :fake, allowed: [@allowed_host]}} =
             Narration.render("private narration", @base_opts ++ [privacy: privacy])
  end

  test "checks every configured step URL for a future cascade descriptor" do
    privacy = %{provider_host_allowlist: ["stt.internal", "model.internal", "speech.internal"]}

    assert :ok =
             ProviderPolicy.check(privacy, %{
               id: :cascade,
               base_urls: [
                 "https://stt.internal/v1/audio/transcriptions",
                 "http://model.internal/v1/chat/completions",
                 "https://speech.internal/v1/audio/speech"
               ]
             })

    assert {:error, %{reason: :provider_host_not_allowed, host: "outside.internal"}} =
             ProviderPolicy.check(privacy, %{
               id: :cascade,
               base_urls: [
                 "https://stt.internal/v1/audio/transcriptions",
                 "https://outside.internal/v1/chat/completions",
                 "https://speech.internal/v1/audio/speech"
               ]
             })
  end

  test "fails closed when a configured provider base URL cannot name a host" do
    privacy = %{provider_host_allowlist: [@allowed_host]}

    assert {:error, %{reason: :provider_host_invalid, provider: :fake}} =
             ProviderPolicy.check(privacy, %{id: :fake, base_urls: ["/v1/audio/speech"]})
  end

  test "validates the provider host allowlist as host names, not URLs" do
    assert :ok = ProviderPolicy.validate(%{provider_host_allowlist: [@allowed_host, "127.0.0.1"]})

    assert {:error, %{field: :privacy, reason: :invalid, key: :provider_host_allowlist}} =
             ProviderPolicy.validate(%{provider_host_allowlist: ["https://speech.internal"]})
  end
end
