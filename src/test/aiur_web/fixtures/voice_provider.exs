defmodule AiurWeb.VoiceChannelTest.FakeSTT do
  use GenServer
  @behaviour Aiur.Voice.Transcriber

  # Unlinked on purpose: the channel's terminate stops the session, and the
  # test needs to query `stopped?` after the channel has exited without the
  # session dying with it first.
  @impl true
  def start(opts) do
    observer = Application.fetch_env!(:aiur, AiurWeb.VoiceChannelTest.FakeVoiceProvider)[:observer]
    started = GenServer.start(__MODULE__, channel: Keyword.fetch!(opts, :owner), observer: observer)
    with {:ok, pid} <- started, do: send(observer, {:fake_stt_started, pid})
    started
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       channel: Keyword.fetch!(opts, :channel),
       observer: Keyword.fetch!(opts, :observer),
       pushes: [],
       committed?: false,
       stopped?: false
     }}
  end

  @impl true
  def push(pid, audio_base64), do: GenServer.cast(pid, {:push, audio_base64})
  @impl true
  def commit(pid), do: GenServer.cast(pid, :commit)
  @impl true
  def stop(pid), do: GenServer.cast(pid, :stop)

  def transcript(pid, kind, text), do: GenServer.call(pid, {:transcript, kind, text})
  def error(pid, reason, code \\ :provider_error), do: GenServer.call(pid, {:error, reason, code})

  def pushes(pid), do: GenServer.call(pid, :pushes)
  def committed?(pid), do: GenServer.call(pid, :committed?)
  def stopped?(pid), do: GenServer.call(pid, :stopped?)

  @impl true
  def handle_cast({:push, pcm}, state) do
    send(state.observer, {:fake_stt_push, self(), pcm})
    {:noreply, %{state | pushes: [pcm | state.pushes]}}
  end

  def handle_cast(:commit, state) do
    send(state.observer, {:fake_stt_commit, self()})
    {:noreply, %{state | committed?: true}}
  end

  def handle_cast(:stop, state) do
    send(state.observer, {:fake_stt_stop, self()})
    {:noreply, %{state | stopped?: true}}
  end

  @impl true
  def handle_call({:transcript, kind, text}, _from, state) do
    send(state.channel, {:voice_transcript, kind, text})
    {:reply, :ok, state}
  end

  def handle_call({:error, reason, code}, _from, state) do
    send(state.channel, {:voice_error, %{code: code, message: reason}})
    {:reply, :ok, state}
  end

  def handle_call(:pushes, _from, state), do: {:reply, Enum.reverse(state.pushes), state}
  def handle_call(:committed?, _from, state), do: {:reply, state.committed?, state}
  def handle_call(:stopped?, _from, state), do: {:reply, state.stopped?, state}
end

defmodule AiurWeb.VoiceChannelTest.FakeVoiceProvider do
  @behaviour Aiur.Voice.Provider
  @impl true
  def transcriber, do: AiurWeb.VoiceChannelTest.FakeSTT
  @impl true
  def synthesizer, do: AiurWeb.VoiceChannelTest.FakeSpeech
  @impl true
  def configured?, do: true
  @impl true
  def child_specs, do: []
  @impl true
  def quota_snapshot, do: %{state: :unconfigured, window: nil, failure: nil, observed_at: nil}
end

defmodule AiurWeb.VoiceChannelTest.UnconfiguredProvider do
  @behaviour Aiur.Voice.Provider
  @impl true
  def transcriber, do: Aiur.ElevenLabs.Realtime
  @impl true
  def synthesizer, do: AiurWeb.VoiceChannelTest.FakeSpeech
  @impl true
  def configured?, do: false
  @impl true
  def child_specs, do: []
  @impl true
  def quota_snapshot, do: %{state: :unconfigured, window: nil, failure: nil, observed_at: nil}
end

defmodule AiurWeb.VoiceChannelTest.FakeSpeech do
  @behaviour Aiur.Voice.Synthesizer
  @impl true
  def start(owner, text, _opts) do
    config = Application.fetch_env!(:aiur, AiurWeb.VoiceChannelTest.FakeVoiceProvider)

    case config[:speech] do
      :unavailable ->
        {:error, :unavailable}

      :blocking ->
        send(config[:observer], {:blocking_tts_started, text})
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}

      _ ->
        send(config[:observer], {:fake_tts_request, text})

        {:ok,
         spawn(fn ->
           send(owner, {:voice_audio, :chunk, <<1, 2, 3, 4>>})
           send(owner, {:voice_audio, :done})
         end)}
    end
  end
end
