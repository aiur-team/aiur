defmodule Aiur.ElevenLabs.Realtime do
  @moduledoc """
  One streaming ElevenLabs speech-to-text session.

  ElevenLabs exposes a genuine bidirectional websocket for transcription
  (`scribe_v2_realtime`), so audio streams as it is captured and partial text
  comes back in roughly 150 ms. Batching short clips through the file endpoint
  would add a round trip per utterance and could not drive a live readout at
  all, so the websocket is the path taken here.

  Protocol reference:
  https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime

  Aiur — not the Stream Deck sidecar — holds the credential and performs this
  call. The sidecar relays base64 PCM over its already-authenticated
  `streamdeck:fleet` channel and `ELEVENLABS_API_KEY` never exists in the
  sidecar process. Because the provider's own frame is base64-in-JSON, the
  string the sidecar produced is the string the provider receives: this module
  does zero transcode.

  ## The credential

  The API key is a secret and is handled exactly as `Aiur.ElevenLabs.Quota`
  handles it:

    * It travels in the `xi-api-key` **request header**, never in the URL,
      because a URL is the thing that ends up in logs and error messages.
      ElevenLabs also accepts a single-use `token` query parameter, but that is
      the *browser* answer: it still puts a credential in a URL, and being
      consumed on use it would force a REST round trip before every reconnect.
    * It is resolved inside the connect step and discarded there. It is never
      written into this GenServer's state, so a `:sys.get_state/1`, a crash
      dump, or an observer session cannot show it.
    * A raised or returned failure value is discarded rather than logged or
      attached to a reason, because it can carry the request that raised and the
      request carries the key.

  An absent key is not a failure. `start/1` and `start_link/1` return
  `{:error, :unconfigured}` so the device can say *why* the microphone is off.

  ## Messages to the owner

    * `{:elevenlabs_transcript, :partial | :final, text}`
    * `{:elevenlabs_error, reason_binary}`
    * `{:elevenlabs_closed}`
  """

  use GenServer

  alias Aiur.Config
  alias Aiur.ElevenLabs.Realtime.MintTransport

  @realtime_url "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
  @model "scribe_v2_realtime"
  @default_sample_rate 16_000

  # How long to wait for the server to settle the final utterance after the
  # commit flush before closing anyway. It is driven through an injectable
  # scheduler so no test waits on elapsed time.
  @flush_timeout_ms 2_000
  @ready_timeout_ms 10_000
  @max_backlog_bytes 426_668

  # `committed_transcript` is the authoritative settled text. `final_transcript`
  # is still revisable despite its name, so it is treated as a *partial* —
  # keeping it as final would duplicate phrases in the operator's message.
  @final_types ~w(committed_transcript committed_transcript_with_timestamps)
  @partial_types ~w(partial_transcript final_transcript final_transcript_with_timestamps)

  # The documented error frames, matched as an explicit set.
  #
  # A `*_error` suffix heuristic looks tempting and is wrong: it silently misses
  # `error`, `invalid_request`, `quota_exceeded`, `rate_limited` and the rest,
  # which would leave a dead session looking merely quiet.
  @error_types ~w(
    error auth_error quota_exceeded commit_throttled unaccepted_terms rate_limited
    queue_overflow resource_exhausted session_time_limit_exceeded input_error
    invalid_request chunk_size_exceeded insufficient_audio_activity transcriber_error
  )

  @connection_failure "Speech-to-text connection failed"

  @typedoc "Arranges for `:flush_deadline` to reach the calling process after `delay_ms`."
  @type scheduler :: (pos_integer() -> any())

  @doc """
  Start a session unlinked. The caller is expected to monitor it: a provider
  fault must be able to end the session without ending the surface that opened
  it.
  """
  @spec start(keyword()) :: GenServer.on_start() | {:error, :unconfigured}
  def start(opts), do: boot(&GenServer.start/3, opts)

  @doc "Start a session linked to the caller. See `start/1` for the unlinked form."
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :unconfigured}
  def start_link(opts), do: boot(&GenServer.start_link/3, opts)

  @doc "Relay one base64 PCM frame verbatim. Nothing is decoded or re-encoded here."
  @spec push(GenServer.server(), String.t()) :: :ok
  def push(server, audio_base64) when is_binary(audio_base64) do
    GenServer.cast(server, {:push, audio_base64})
  catch
    :exit, _reason -> :ok
  end

  @doc "Seal the utterance with the documented empty-chunk commit flush, then close."
  @spec commit(GenServer.server()) :: :ok
  def commit(server) do
    GenServer.cast(server, :commit)
  catch
    :exit, _reason -> :ok
  end

  @doc "Close a session immediately without committing the current utterance."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.cast(server, :stop)
  catch
    :exit, _reason -> :ok
  end

  # The credential is resolved twice on purpose: once here, only to learn
  # whether one exists at all, and once inside the connect step that uses it.
  # Neither reading is kept. Testing presence up front is what turns "no key"
  # into a plain `{:error, :unconfigured}` the device can render, instead of a
  # started session that immediately fails.
  defp boot(start_fun, opts) do
    api_key_fun = Keyword.get(opts, :api_key_fun, &Config.elevenlabs_api_key/0)

    if configured?(api_key_fun) do
      start_fun.(__MODULE__, opts, Keyword.take(opts, [:name]))
    else
      {:error, :unconfigured}
    end
  end

  defp configured?(api_key_fun) do
    case api_key_fun.() do
      key when is_binary(key) -> String.trim(key) != ""
      _absent -> false
    end
  rescue
    _unavailable -> false
  catch
    _kind, _reason -> false
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)
    send(self(), :connect)

    ready_timeout_ms = Keyword.get(opts, :ready_timeout_ms, @ready_timeout_ms)
    ready_scheduler = Keyword.get(opts, :ready_scheduler, &default_ready_scheduler/1)
    ready_scheduler.(ready_timeout_ms)

    {:ok,
     %{
       owner: owner,
       # `api_key_fun` is a zero-arity reader, not the key. It is called once,
       # inside `handle_info(:connect, …)`, and what it returns is never stored.
       api_key_fun: Keyword.get(opts, :api_key_fun, &Config.elevenlabs_api_key/0),
       language_code: Keyword.get(opts, :language_code) || language_code(),
       sample_rate: Keyword.get(opts, :sample_rate, @default_sample_rate),
       transport: Keyword.get(opts, :transport, MintTransport),
       flush_timeout_ms: Keyword.get(opts, :flush_timeout_ms, @flush_timeout_ms),
       scheduler: Keyword.get(opts, :scheduler, &default_scheduler/1),
       max_backlog_bytes: Keyword.get(opts, :max_backlog_bytes, @max_backlog_bytes),
       conn: nil,
       ready?: false,
       flushing?: false,
       commit_pending?: false,
       backlog: [],
       backlog_bytes: 0
     }}
  end

  @impl true
  def handle_cast({:push, audio_base64}, state) do
    cond do
      # Once flushing, the utterance is sealed; more audio would reopen it.
      state.flushing? -> {:noreply, state}
      state.ready? -> {:noreply, transmit(state, audio_base64, false)}
      # Audio captured before the server reports `session_started` would be
      # discarded, so it queues and flushes on that frame. Losing the first word
      # of every hold is exactly what makes voice input feel unreliable, and the
      # socket being open is not the same as the session being ready.
      true -> queue_audio(state, audio_base64)
    end
  end

  def handle_cast(:commit, %{flushing?: true} = state), do: {:noreply, state}

  # Nothing was ever captured, so there is nothing to settle.
  def handle_cast(:commit, %{ready?: false, backlog: []} = state), do: finish(state)

  # The operator may release the microphone before ElevenLabs emits
  # `session_started`. Preserve and seal the queued utterance instead of
  # silently dropping the whole recording.
  def handle_cast(:commit, %{ready?: false} = state),
    do: {:noreply, %{state | commit_pending?: true}}

  def handle_cast(:commit, state) do
    # An empty chunk with `commit` set is the documented way to seal the final
    # utterance. Closing the socket without it drops whatever the server had not
    # yet committed — the tail of what was just said.
    state = transmit(state, "", true)
    state.scheduler.(state.flush_timeout_ms)
    {:noreply, %{state | flushing?: true}}
  end

  def handle_cast(:stop, state) do
    close_transport(state)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state) do
      {:ok, conn} -> {:noreply, %{state | conn: conn}}
      # The failure value is deliberately not rendered: it can embed the request
      # headers, and those carry the API key.
      {:error, _opaque} -> fail(state, @connection_failure)
    end
  end

  def handle_info({:elevenlabs_transport, :text, frame}, state) when is_binary(frame) do
    case decode(frame) do
      # A malformed frame is the provider's problem, not a reason to tear down a
      # working session; the next frame usually parses.
      :error -> {:noreply, state}
      {:ok, message} -> handle_message(message, state)
    end
  end

  def handle_info({:elevenlabs_transport, :closed}, state), do: finish(state)

  def handle_info({:elevenlabs_transport, :error, _opaque}, state), do: fail(state, @connection_failure)

  def handle_info(:ready_deadline, %{ready?: false} = state),
    do: fail(state, "Speech-to-text session did not become ready")

  def handle_info(:ready_deadline, state), do: {:noreply, state}

  # The settled utterance never arrived inside the flush window. Close anyway
  # rather than holding a session open on a provider that has gone quiet.
  def handle_info(:flush_deadline, state), do: finish(state)

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    close_transport(state)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_message(%{"message_type" => "session_started"}, state) do
    state =
      Enum.reduce(
        Enum.reverse(state.backlog),
        %{state | ready?: true, backlog: [], backlog_bytes: 0},
        &transmit(&2, &1, false)
      )

    if state.commit_pending? do
      state = transmit(state, "", true)
      state.scheduler.(state.flush_timeout_ms)
      {:noreply, %{state | flushing?: true, commit_pending?: false}}
    else
      {:noreply, state}
    end
  end

  defp handle_message(%{"message_type" => type} = message, state) when type in @final_types do
    notify(state, {:elevenlabs_transcript, :final, text(message)})

    # The settled utterance we were waiting for after the commit flush; closing
    # before it arrived is what clipped the last words.
    if state.flushing?, do: finish(state), else: {:noreply, state}
  end

  defp handle_message(%{"message_type" => type} = message, state) when type in @partial_types do
    notify(state, {:elevenlabs_transcript, :partial, text(message)})
    {:noreply, state}
  end

  defp handle_message(%{"message_type" => type} = message, state) when type in @error_types do
    fail(state, describe_failure(type, Map.get(message, "error")))
  end

  defp handle_message(_message, state), do: {:noreply, state}

  defp connect(state) do
    url = realtime_url(state.sample_rate, state.language_code)

    case api_key(state.api_key_fun) do
      # The key is bound only for the length of this call and is handed straight
      # to the transport as a request header. It is never returned into state.
      {:ok, api_key} -> state.transport.connect(url, [{"xi-api-key", api_key}])
      :none -> {:error, :unconfigured}
    end
  rescue
    _error -> {:error, :connect_failed}
  catch
    _kind, _reason -> {:error, :connect_failed}
  end

  defp api_key(api_key_fun) do
    case api_key_fun.() do
      key when is_binary(key) -> if String.trim(key) == "", do: :none, else: {:ok, key}
      _absent -> :none
    end
  rescue
    _unavailable -> :none
  catch
    _kind, _reason -> :none
  end

  # Only the `pcm_<rate>` formats ElevenLabs documents; capture uses 16 kHz.
  # `commit_strategy=vad` makes voice activity detection commit an utterance on
  # a natural pause, which is what settles text while the operator is still
  # holding the key.
  defp realtime_url(sample_rate, language_code) do
    query =
      URI.encode_query(%{
        "model_id" => @model,
        "audio_format" => "pcm_#{sample_rate}",
        "language_code" => language_code,
        "commit_strategy" => "vad"
      })

    @realtime_url <> "?" <> query
  end

  defp transmit(%{conn: nil} = state, _audio_base64, _commit), do: state

  defp transmit(state, audio_base64, commit) do
    frame =
      Jason.encode!(%{
        "message_type" => "input_audio_chunk",
        "audio_base_64" => audio_base64,
        "commit" => commit,
        "sample_rate" => state.sample_rate
      })

    case state.transport.send_text(state.conn, frame) do
      {:ok, conn} ->
        %{state | conn: conn}

      # Do not retry: a repeated chunk would arrive out of order. Schedule the
      # normal transport-failure path so the owner is told this utterance did
      # not make it to the provider instead of presenting a silent success.
      {:error, _opaque} ->
        send(self(), {:elevenlabs_transport, :error, :send_failed})
        state
    end
  end

  defp queue_audio(state, audio_base64) do
    backlog_bytes = state.backlog_bytes + byte_size(audio_base64)

    if backlog_bytes > state.max_backlog_bytes do
      fail(state, "Speech-to-text session did not become ready")
    else
      {:noreply, %{state | backlog: [audio_base64 | state.backlog], backlog_bytes: backlog_bytes}}
    end
  end

  # Seal before notifying, never after. The channel above reacts to
  # `{:elevenlabs_error, …}` by stopping this session, and a session still
  # holding an open connection would answer that by flushing a commit frame on a
  # connection that has just failed.
  defp fail(state, reason) do
    close_transport(state)
    notify(state, {:elevenlabs_error, reason})
    notify(state, {:elevenlabs_closed})
    {:stop, :normal, state}
  end

  defp finish(state) do
    close_transport(state)
    notify(state, {:elevenlabs_closed})
    {:stop, :normal, state}
  end

  defp close_transport(%{conn: nil}), do: :ok
  defp close_transport(state), do: state.transport.close(state.conn)

  defp notify(state, message), do: send(state.owner, message)

  defp decode(frame) do
    case Jason.decode(frame) do
      {:ok, message} when is_map(message) -> {:ok, message}
      _other -> :error
    end
  end

  defp text(%{"text" => text}) when is_binary(text), do: text
  defp text(_message), do: ""

  # Turns a provider error frame into something an operator can act on.
  defp describe_failure("auth_error", _detail), do: "ElevenLabs rejected the API key"
  defp describe_failure("quota_exceeded", _detail), do: "ElevenLabs quota exhausted"
  defp describe_failure("rate_limited", _detail), do: "ElevenLabs rate limit reached"
  defp describe_failure("commit_throttled", _detail), do: "ElevenLabs rate limit reached"
  defp describe_failure("unaccepted_terms", _detail), do: "ElevenLabs terms not accepted for this account"
  defp describe_failure("session_time_limit_exceeded", _detail), do: "ElevenLabs session time limit reached"
  defp describe_failure(_type, detail) when is_binary(detail) and detail != "", do: detail
  defp describe_failure(_type, _detail), do: "Speech-to-text failed"

  defp default_scheduler(delay_ms), do: Process.send_after(self(), :flush_deadline, delay_ms)
  defp default_ready_scheduler(delay_ms), do: Process.send_after(self(), :ready_deadline, delay_ms)

  defp language_code do
    Config.elevenlabs_language_code()
  rescue
    _unavailable -> "eng"
  catch
    _kind, _reason -> "eng"
  end
end
