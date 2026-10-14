defmodule Aiur.BrowserHarness.VoiceProvider do
  @behaviour Aiur.Voice.Provider

  @impl true
  def transcriber, do: Aiur.BrowserHarness.VoiceTranscriber
  @impl true
  def synthesizer, do: Aiur.BrowserHarness.VoiceSpeech
  @impl true
  def configured?, do: true
end

defmodule Aiur.BrowserHarness.VoiceTranscriber do
  @behaviour Aiur.Voice.Transcriber

  alias Aiur.BrowserHarness.VoiceSTT

  @impl true
  def start(opts), do: VoiceSTT.start_link(Keyword.fetch!(opts, :owner))
  @impl true
  def push(pid, audio), do: GenServer.cast(pid, {:push, audio})
  @impl true
  def commit(pid), do: GenServer.cast(pid, :commit)
  @impl true
  def stop(pid), do: GenServer.cast(pid, :stop)
end

defmodule Aiur.BrowserHarness.VoiceSpeech do
  @behaviour Aiur.Voice.Synthesizer

  @impl true
  def start(owner, text, _opts) do
    Task.start(fn ->
      if text == "Voice reply from the agent." do
        send(owner, {:voice_audio, :chunk, <<0, 0, 255, 127, 0, 0, 1, 128>>})
        send(owner, {:voice_audio, :done})
      else
        send(owner, {:voice_audio, :error, "fixture received an incomplete reply"})
      end
    end)
  end
end
