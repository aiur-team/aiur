defmodule AiurWeb.StreamdeckProjectionTest do
  use ExUnit.Case, async: false

  alias AiurWeb.StreamdeckProjection

  defmodule VoiceProvider do
    @behaviour Aiur.Voice.Provider
    @impl true
    def transcriber, do: nil
    @impl true
    def synthesizer, do: nil
    @impl true
    def configured?, do: false
    @impl true
    def child_specs, do: []
    @impl true
    def quota_snapshot, do: %{state: :unconfigured, window: nil, failure: nil, observed_at: nil}
  end

  defmodule ConfiguredVoiceProvider do
    @behaviour Aiur.Voice.Provider
    @impl true
    def transcriber, do: nil
    @impl true
    def synthesizer, do: nil
    @impl true
    def configured?, do: true
    @impl true
    def child_specs, do: []
    @impl true
    def quota_snapshot, do: %{state: :unconfigured, window: nil, failure: nil, observed_at: nil}
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

  test "voice availability follows the voice port" do
    Application.put_env(:aiur, :voice_provider, VoiceProvider)
    assert Aiur.Voice.availability() == %{available: false, reason: :unconfigured}
    assert StreamdeckProjection.voice() == %{available: false, reason: "Aiur has no ElevenLabs API key - transcription is off"}

    Application.put_env(:aiur, :voice_provider, ConfiguredVoiceProvider)
    assert Aiur.Voice.availability() == %{available: true, reason: nil}
    assert StreamdeckProjection.voice() == %{available: true, reason: nil}

    Application.put_env(:aiur, :voice_provider, nil)
    assert Aiur.Voice.availability() == %{available: false, reason: :not_installed}
    assert StreamdeckProjection.voice() == %{available: false, reason: "Voice isn't installed in this Aiur"}
  end
end
