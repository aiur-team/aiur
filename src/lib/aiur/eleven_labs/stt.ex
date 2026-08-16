defmodule Aiur.ElevenLabs.STT do
  @moduledoc """
  Server-side ElevenLabs realtime speech-to-text session.

  The Stream Deck voice stack (#1930) transcribes inside a Node sidecar that
  captures through PipeWire; a browser cannot run that capture layer. This
  module is the shared server-side seam the dashboard feeds: the browser
  captures raw PCM and pushes it over a Phoenix channel, and this process owns
  the ElevenLabs websocket session. It mirrors the `scribe_v2_realtime`
  protocol the Node sidecar uses, so both producers feed the same transcription
  service rather than duplicating the integration.

  The API key travels as a request header and never leaves this process (the
  key is never a URL component, never a channel payload, and never logged).
  The session sends transcript frames to its `:owner` process as
  `{:stt_transcript, kind, text}` and terminal failures as `{:stt_error, reason}`.

  Protocol reference:
  https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
  """

  use GenServer

  alias Aiur.ElevenLabs.STT.{Connection, Protocol}
  alias AiurWeb.Endpoint

  @default_base_url "wss://api.elevenlabs.io"
  @default_sample_rate 16_000
  @default_flush_timeout_ms 2_000
  @default_connect_timeout_ms 10_000
  @max_backlog_bytes 320_000

  @type kind :: :partial | :final

  @type options :: [
          owner: pid(),
          api_key: String.t(),
          language_code: String.t() | nil,
          sample_rate: pos_integer() | nil,
          base_url: String.t() | nil,
          connect_timeout_ms: pos_integer() | nil,
          flush_timeout_ms: pos_integer() | nil
        ]

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Pushes one chunk of raw 16 kHz mono PCM16 into the open transcription."
  @spec push(GenServer.server(), binary()) :: :ok
  def push(server, pcm) when is_binary(pcm) do
    GenServer.cast(server, {:push, pcm})
  end

  @doc "Seals the current utterance and closes the session (the commit flush)."
  @spec commit(GenServer.server()) :: :ok
  def commit(server) do
    GenServer.cast(server, :commit)
  end

  @doc "Closes the session immediately without a commit flush."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.cast(server, :stop)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    api_key = Keyword.fetch!(opts, :api_key)
    language_code = Keyword.get(opts, :language_code) || Aiur.Config.elevenlabs_language_code()
    sample_rate = Keyword.get(opts, :sample_rate) || @default_sample_rate
    base_url = Keyword.get(opts, :base_url) || Endpoint.config(:elevenlabs_stt_base_url) || @default_base_url
    connect_timeout_ms = Keyword.get(opts, :connect_timeout_ms) || @default_connect_timeout_ms
    flush_timeout_ms = Keyword.get(opts, :flush_timeout_ms) || @default_flush_timeout_ms

    state = %{
      owner: owner,
      api_key: api_key,
      language_code: language_code,
      sample_rate: sample_rate,
      base_url: base_url,
      connect_timeout_ms: connect_timeout_ms,
      flush_timeout_ms: flush_timeout_ms,
      phase: :connecting,
      conn: nil,
      backlog: [],
      backlog_bytes: 0,
      ready_ref: nil,
      flush_ref: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    url = state.base_url |> URI.merge(Protocol.path(state.base_url, state.sample_rate, state.language_code)) |> URI.to_string()

    case Connection.open(url, state.api_key, self(), state.connect_timeout_ms) do
      {:ok, conn} ->
        ready_ref = Process.send_after(self(), :ready_timeout, state.connect_timeout_ms)
        {:noreply, %{state | conn: conn, phase: :opening, ready_ref: ready_ref}}

      {:error, reason} ->
        {:noreply, fail(state, "Speech-to-text connection failed: #{describe_connect(reason)}")}
    end
  end

  @impl true
  def handle_cast({:push, pcm}, %{phase: phase} = state) when phase in [:connecting, :opening, :ready] do
    {:noreply, push_audio(state, pcm)}
  end

  def handle_cast({:push, _pcm}, state), do: {:noreply, state}

  def handle_cast(:commit, state) do
    {:noreply, commit_session(state)}
  end

  def handle_cast(:stop, state) do
    {:noreply, finish(state)}
  end

  @impl true
  def handle_info({:stt_connection, conn, :connected}, %{conn: conn} = state) do
    # Audio stays queued until the provider confirms session_started. Do not
    # rewrite the phase here: the operator may already have released the mic,
    # sealing this session as :commit_pending while the socket connected.
    {:noreply, state}
  end

  def handle_info({:stt_connection, conn, {:text, data}}, %{conn: conn} = state) do
    {:noreply, handle_provider_frame(state, data)}
  end

  def handle_info({:stt_connection, conn, {:disconnected, _reason}}, %{conn: conn} = state) do
    reason =
      if state.phase == :committing,
        do: "Speech-to-text connection closed before the final transcript arrived",
        else: "Speech-to-text connection closed"

    {:noreply, finish(state, error: reason)}
  end

  def handle_info({:stt_send_failed, conn}, %{conn: conn} = state) do
    {:noreply, finish(state, error: "Speech-to-text connection failed")}
  end

  def handle_info(:flush_timeout, state) do
    {:noreply, finish(state, error: "Speech-to-text final transcript timed out")}
  end

  def handle_info(:ready_timeout, %{phase: phase} = state)
      when phase in [:opening, :commit_pending] do
    {:noreply, finish(state, error: "Speech-to-text session did not become ready")}
  end

  def handle_info(:ready_timeout, state), do: {:noreply, state}

  def handle_info(:terminate_session, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Connection.shutdown(state.conn)
    :ok
  end

  # --- audio / provider frames --------------------------------------------

  defp push_audio(state, pcm) do
    if state.phase == :closed do
      state
    else
      encoded = Base.encode64(pcm)

      if state.phase == :ready do
        transmit(state, encoded, false)
        state
      else
        backlog_bytes = state.backlog_bytes + byte_size(pcm)

        if backlog_bytes > @max_backlog_bytes do
          finish(state, error: "Speech-to-text session did not become ready")
        else
          # Queue until session_started so the first word is never dropped.
          %{state | backlog: [encoded | state.backlog], backlog_bytes: backlog_bytes}
        end
      end
    end
  end

  defp commit_session(%{phase: :closed} = state), do: state

  defp commit_session(%{phase: phase, backlog: []} = state)
       when phase in [:connecting, :opening] do
    finish(state)
  end

  defp commit_session(%{phase: phase} = state) when phase in [:connecting, :opening] do
    # The operator may release the mic before ElevenLabs emits session_started.
    # Keep the queued utterance sealed; readiness will flush it and immediately
    # send the commit frame instead of silently dropping the whole recording.
    %{state | phase: :commit_pending}
  end

  defp commit_session(%{phase: :ready, flush_ref: nil} = state) do
    # An empty chunk with `commit` set seals the final utterance; closing the
    # socket without it drops whatever the server had not yet committed.
    transmit(state, "", true)

    state
    |> cancel_flush()
    |> put_flush_timer()
    |> Map.put(:phase, :committing)
  end

  defp commit_session(state), do: state

  defp handle_provider_frame(%{phase: :closed} = state, _data), do: state

  defp handle_provider_frame(state, data) do
    case Protocol.decode(data) do
      :session_started ->
        commit_pending? = state.phase == :commit_pending

        state =
          state
          |> cancel_ready()
          |> flush_backlog()
          |> Map.put(:phase, :ready)

        if commit_pending?, do: commit_session(state), else: state

      {:transcript, :final, text} ->
        notify(state, {:stt_transcript, :final, text})

        # The settled utterance we were waiting for after the commit flush;
        # closing before it arrived clipped the last words.
        if state.phase == :committing do
          finish(state)
        else
          state
        end

      {:transcript, :partial, text} ->
        notify(state, {:stt_transcript, :partial, text})
        state

      {:error, reason} ->
        fail(state, reason)

      :ignore ->
        state
    end
  end

  defp flush_backlog(state) do
    Enum.each(Enum.reverse(state.backlog), &transmit(state, &1, false))
    %{state | backlog: [], backlog_bytes: 0}
  end

  defp transmit(state, audio_base64, commit?) do
    payload = Protocol.audio_frame(audio_base64, state.sample_rate, commit?)

    if Connection.send_text(state.conn, payload) != :ok do
      send(self(), {:stt_send_failed, state.conn})
    end

    :ok
  end

  defp put_flush_timer(state) do
    ref = Process.send_after(self(), :flush_timeout, state.flush_timeout_ms)
    %{state | flush_ref: ref}
  end

  defp cancel_flush(state) do
    if state.flush_ref, do: Process.cancel_timer(state.flush_ref)
    %{state | flush_ref: nil}
  end

  defp cancel_ready(state) do
    if state.ready_ref, do: Process.cancel_timer(state.ready_ref)
    %{state | ready_ref: nil}
  end

  # --- terminal handling ---------------------------------------------------

  # An orderly finish after a commit flush: no error is reported, the settled
  # transcript has already been delivered as `:final`.
  defp finish(state), do: finish(state, error: nil)

  defp finish(state, opts) do
    error = Keyword.get(opts, :error)

    if state.phase == :closed do
      state
    else
      state = state |> cancel_flush() |> cancel_ready() |> Map.put(:phase, :closed)

      if error do
        notify(state, {:stt_error, error})
      else
        notify(state, {:stt_stopped, :ok})
      end

      Connection.shutdown(state.conn)
      send(self(), :terminate_session)
      state
    end
  end

  defp fail(state, reason) do
    state = state |> cancel_flush() |> cancel_ready() |> Map.put(:phase, :closed)
    notify(state, {:stt_error, reason})
    Connection.shutdown(state.conn)
    send(self(), :terminate_session)
    state
  end

  defp notify(state, message), do: send(state.owner, message)

  defp describe_connect(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe_connect(reason), do: inspect(reason)
end
