defmodule Aiur.VoiceQuotaTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Aiur.GitHub.{BrokerTimeout, BudgetBroker}
  alias Aiur.Voice

  @unconfigured %{state: :unconfigured, window: nil, failure: nil, observed_at: nil}
  @observed %{state: :observed, window: %{used_percent: 10.0, remaining: 90, reset_at: nil}, failure: nil, observed_at: nil}

  defmodule Provider do
    @behaviour Aiur.Voice.Provider
    @impl true
    def transcriber, do: Aiur.VoiceTest.Transcriber
    @impl true
    def synthesizer, do: Aiur.VoiceTest.Synthesizer
    @impl true
    def configured?, do: true
    @impl true
    def child_specs, do: [Aiur.VoiceQuotaTest.Provider]
    @impl true
    def quota_snapshot, do: %{state: :observed, window: %{used_percent: 10.0, remaining: 90, reset_at: nil}, failure: nil, observed_at: nil}
  end

  setup do
    previous = Application.fetch_env(:aiur, :voice_provider)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :voice_provider, value)
        :error -> Application.delete_env(:aiur, :voice_provider)
      end
    end)
  end

  test "child specs and quota observations come from the selected provider" do
    Application.put_env(:aiur, :voice_provider, Provider)
    assert Voice.child_specs() == [Provider]
    assert Voice.quota_snapshot() == @observed
  end

  test "the default provider owns the ElevenLabs quota child" do
    Application.delete_env(:aiur, :voice_provider)
    assert Voice.child_specs() == [Aiur.ElevenLabs.Quota]
  end

  test "an absent or unloadable provider has no child and exactly an unconfigured quota" do
    for provider <- [nil, Aiur.VoiceQuotaTest.Missing] do
      Application.put_env(:aiur, :voice_provider, provider)
      assert Voice.child_specs() == []
      assert Voice.quota_snapshot() == @unconfigured
    end
  end

  test "voice children retain the quota boot position and disappear without a provider" do
    Application.delete_env(:aiur, :voice_provider)
    children = children()
    index = Enum.find_index(children, &(&1 == BudgetBroker.child_spec([])))
    assert Enum.at(children, index - 2) == BrokerTimeout.child_spec([])
    assert Enum.at(children, index - 1) == Aiur.GitHub.HoldPressure
    assert Enum.at(children, index + 1) == Aiur.ElevenLabs.Quota

    Application.put_env(:aiur, :voice_provider, Provider)
    assert Enum.at(children(), index + 1) == Provider
    refute Aiur.ElevenLabs.Quota in children()

    Application.put_env(:aiur, :voice_provider, nil)
    refute Aiur.ElevenLabs.Quota in children()
    assert Enum.at(children(), index + 1) == Enum.at(children, index + 2)
  end
end
