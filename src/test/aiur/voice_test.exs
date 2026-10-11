defmodule Aiur.VoiceTest do
  use ExUnit.Case, async: false

  alias Aiur.Voice

  defmodule Transcriber do
    @behaviour Aiur.Voice.Transcriber

    @impl true
    def start(opts), do: {:ok, Keyword.fetch!(opts, :owner)}
    @impl true
    def push(pid, audio), do: send(pid, {__MODULE__, :push, audio}) && :ok
    @impl true
    def commit(pid), do: send(pid, {__MODULE__, :commit}) && :ok
    @impl true
    def stop(pid), do: send(pid, {__MODULE__, :stop}) && :ok
  end

  defmodule OtherTranscriber do
    def push(pid, audio), do: send(pid, {__MODULE__, :push, audio}) && :ok
  end

  defmodule Synthesizer do
    @behaviour Aiur.Voice.Synthesizer

    @impl true
    def start(owner, text, _opts), do: {:ok, send(owner, {__MODULE__, :speak, text}) && owner}
  end

  defmodule Configured do
    @behaviour Aiur.Voice.Provider

    @impl true
    def transcriber, do: Aiur.VoiceTest.Transcriber
    @impl true
    def synthesizer, do: Aiur.VoiceTest.Synthesizer
    @impl true
    def configured?, do: true
  end

  defmodule Unconfigured do
    def transcriber, do: Aiur.VoiceTest.OtherTranscriber
    def configured?, do: false
  end

  defmodule Unreadable do
    def configured?, do: raise("credential store unavailable")
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

  defp provider(module), do: Application.put_env(:aiur, :voice_provider, module)

  test "the default provider is Aiur.ElevenLabs" do
    Application.delete_env(:aiur, :voice_provider)

    assert Voice.provider() == Aiur.ElevenLabs
  end

  test "availability is available when the provider reports a credential" do
    provider(Configured)

    assert Voice.availability() == %{available: true, reason: nil}
  end

  test "availability is unconfigured without a credential" do
    provider(Unconfigured)

    assert Voice.availability() == %{available: false, reason: :unconfigured}
  end

  test "availability is unconfigured when the provider cannot read its credential" do
    provider(Unreadable)

    assert Voice.availability() == %{available: false, reason: :unconfigured}
  end

  test "availability is not_installed without a provider" do
    provider(nil)

    assert Voice.availability() == %{available: false, reason: :not_installed}
  end

  test "a provider module that cannot be loaded is not installed" do
    provider(Aiur.VoiceTest.NoSuchProvider)

    assert Voice.provider() == nil
    assert Voice.availability() == %{available: false, reason: :not_installed}
  end

  test "start_transcription returns not_installed without a provider" do
    provider(nil)

    assert Voice.start_transcription(owner: self()) == {:error, :not_installed}
    assert Voice.start_speech(self(), "hello") == {:error, :not_installed}
  end

  test "a session keeps the transcriber it opened with" do
    provider(Configured)
    assert {:ok, session} = Voice.start_transcription(owner: self())
    assert session == %{pid: self(), module: Transcriber}

    provider(Unconfigured)
    assert Voice.push(session, "audio") == :ok
    assert Voice.commit(session) == :ok
    assert Voice.stop(session) == :ok

    assert_received {Transcriber, :push, "audio"}
    assert_received {Transcriber, :commit}
    assert_received {Transcriber, :stop}
    refute_received {OtherTranscriber, :push, _audio}
  end

  test "start_speech starts the provider's synthesizer" do
    provider(Configured)

    assert Voice.start_speech(self(), "hello") == {:ok, self()}
    assert_received {Synthesizer, :speak, "hello"}
  end
end
