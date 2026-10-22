defmodule VoiceConverse.ProviderPolicyTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.{Config, ProviderPolicy}
  alias VoiceConverse.Testing.{FakeBriefingSource, StaticCredentials}

  # A host serving a privacy-restricted audience: only two providers, each with storage off.
  @restricted %{
    provider_allowlist: [:openai_realtime, :elevenlabs_agents],
    required_provider_options: %{
      openai_realtime: %{store: false},
      elevenlabs_agents: %{record_voice: false}
    }
  }

  describe "default (no policy configured)" do
    # The default must stay permissive: a standalone host that sets no policy can use any provider
    # with any options. Tightening is opt-in per host, never a silent global change.
    test "any provider with any options is allowed" do
      assert :ok = ProviderPolicy.check(%{}, %{id: :gemini_live})
      assert :ok = ProviderPolicy.check(%{}, %{id: :openai_realtime, options: %{store: true}})
    end

    test "a default Config carries no policy and validates" do
      {:ok, config} =
        Config.new(transcript_root: "/tmp/vc", credentials: StaticCredentials, briefing_source: FakeBriefingSource)

      assert config.privacy == %{}
      assert :ok = ProviderPolicy.check(config.privacy, %{id: :anything})
    end
  end

  describe "allowlist" do
    test "a provider not on the allowlist is refused, naming the provider and the allowed set" do
      assert {:error, %{reason: :provider_not_allowed, provider: :gemini_live, allowed: allowed}} =
               ProviderPolicy.check(@restricted, %{id: :gemini_live, options: %{}})

      assert allowed == [:openai_realtime, :elevenlabs_agents]
    end

    test "an empty allowlist allows no provider" do
      assert {:error, %{reason: :provider_not_allowed}} =
               ProviderPolicy.check(%{provider_allowlist: []}, %{id: :openai_realtime})
    end

    test "an allowed provider meeting its required options is allowed" do
      assert :ok = ProviderPolicy.check(@restricted, %{id: :openai_realtime, options: %{store: false, voice: "x"}})
    end

    test "an allowed provider with no required-options entry has none to meet" do
      assert :ok = ProviderPolicy.check(%{provider_allowlist: [:cascade]}, %{id: :cascade})
    end
  end

  describe "required no-logging options" do
    test "an allowed provider lacking its no-logging option is refused as missing" do
      assert {:error,
              %{
                reason: :required_option_unmet,
                provider: :elevenlabs_agents,
                option: :record_voice,
                expected: false,
                actual: :missing
              }} = ProviderPolicy.check(@restricted, %{id: :elevenlabs_agents, options: %{}})
    end

    test "an allowed provider with logging turned on is refused with the actual value" do
      assert {:error, %{reason: :required_option_unmet, option: :store, expected: false, actual: {:ok, true}}} =
               ProviderPolicy.check(@restricted, %{id: :openai_realtime, options: %{store: true}})
    end

    # A falsy-but-wrong value (nil) must not pass for `false`: "not set" is not "storage off".
    test "nil does not satisfy a required false" do
      assert {:error, %{actual: {:ok, nil}}} =
               ProviderPolicy.check(@restricted, %{id: :openai_realtime, options: %{store: nil}})
    end

    test "required options apply without an allowlist" do
      policy = %{required_provider_options: %{openai_realtime: %{store: false}}}

      assert {:error, %{reason: :required_option_unmet}} = ProviderPolicy.check(policy, %{id: :openai_realtime})
      assert :ok = ProviderPolicy.check(policy, %{id: :gemini_live})
    end
  end

  describe "validate/1 via Config" do
    @base [transcript_root: "/tmp/vc", credentials: StaticCredentials, briefing_source: FakeBriefingSource]

    test "a well-formed policy is accepted" do
      assert {:ok, %Config{privacy: @restricted}} = Config.new(@base ++ [privacy: @restricted])
    end

    # A malformed policy must fail at config time, not silently allow providers at session time.
    test "a malformed allowlist fails naming the key" do
      assert {:error, %{field: :privacy, key: :provider_allowlist}} =
               Config.new(@base ++ [privacy: %{provider_allowlist: "openai_realtime"}])
    end

    test "malformed required options fail naming the key" do
      assert {:error, %{field: :privacy, key: :required_provider_options}} =
               Config.new(@base ++ [privacy: %{required_provider_options: %{openai_realtime: [store: false]}}])
    end

    test "a non-map privacy value fails" do
      assert {:error, %{field: :privacy, reason: :invalid}} = Config.new(@base ++ [privacy: nil])
    end
  end
end
