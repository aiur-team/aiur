defmodule VoiceConverse.ProviderSafetyTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Config, Providers}
  alias VoiceConverse.Session.Start
  alias VoiceConverse.Testing.{FakeBriefingSource, FakeProvider, StaticCredentials}

  setup do
    StaticCredentials.put(%{elevenlabs: "test-key", anthropic: "test-key"})
    on_exit(fn -> StaticCredentials.put(%{}) end)
    :ok
  end

  test "default missing-key policy never selects outside the configured preference" do
    assert {:ok, config} = new_config(preference: [:openai_live])
    assert config.providers.on_missing_credential == :text_only
    assert {:error, :no_usable_option, [{:openai_live, {:missing_credential, :openai}}]} = Providers.resolve(config)
  end

  test "text-only default never falls through to a different paid voice option" do
    assert {:ok, config} = new_config(preference: [:openai_live, :elevenlabs_agents])
    assert {:error, :no_usable_option, [{:openai_live, {:missing_credential, :openai}}]} = Providers.resolve(config)
  end

  # Deliberate future regression guard for the existing list-only traversal.
  test "next only visits the explicit preference list" do
    assert {:ok, config} = new_config(preference: [:openai_live], on_missing_credential: :next)
    assert {:error, :no_usable_option, [{:openai_live, {:missing_credential, :openai}}]} = Providers.resolve(config)
  end

  test "explicit session provider forces refuse without changing the instance policy" do
    assert {:ok, config} = new_config(on_missing_credential: :next)
    assert {:ok, state} = Start.state(config, %{id: "target"}, "explicit-provider", provider: FakeProvider)
    assert state.provider == FakeProvider
    assert state.config.providers.on_missing_credential == :refuse
    assert config.providers.on_missing_credential == :next
  end

  defp new_config(providers) do
    Config.new(
      transcript: :none,
      credentials: StaticCredentials,
      briefing_source: FakeBriefingSource,
      llm: "test-model",
      cloud_disclosure_accepted: true,
      providers: Map.new(providers) |> Map.put(:cascade, %{llm: "anthropic:test-model"})
    )
  end
end
