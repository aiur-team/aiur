defmodule Aiur.ElevenLabs.RealtimeTest do
  @moduledoc """
  The realtime transcription protocol, exercised without a socket and without a
  clock.

  Both are deliberate. The transport is a behaviour so no test opens a
  connection, and the flush deadline goes through an injected scheduler so no
  test waits for one — #1983 was a flake caused by a deadline smaller than the
  work it bounded, and a suite that sleeps will grow another one.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.ElevenLabs.Realtime

  @api_key "sk-elevenlabs-supersecret-abc123"

  # Captured as a named function rather than an anonymous one so the closure
  # cannot be what holds the key: when the state assertion below says the key is
  # absent, nothing in the state is quietly carrying it.
  def api_key, do: @api_key
  def no_api_key, do: nil
  def blank_api_key, do: "   "

  defmodule FakeTransport do
    @moduledoc false
    @behaviour Aiur.ElevenLabs.Realtime.Transport

    @impl true
    def connect(url, headers) do
      send(observer(), {:transport_connect, url, headers})
      {:ok, self()}
    end

    @impl true
    def send_text(conn, text) do
      send(observer(), {:transport_send, text})
      {:ok, conn}
    end

    @impl true
    def close(_conn) do
      if observer = observer(), do: send(observer, :transport_close)
      :ok
    end

    # The transport runs inside the session process, so it reaches the test
    # through a registered name rather than a closure.
    defp observer, do: Process.whereis(:realtime_test_observer)
  end

  defmodule FailingTransport do
    @moduledoc """
    Fails the way the real one can: the error value embeds the request headers,
    and those headers carry the API key. Anything that renders this value leaks
    the credential.
    """
    @behaviour Aiur.ElevenLabs.Realtime.Transport

    @impl true
    def connect(url, headers), do: {:error, %Mint.TransportError{reason: {:request, url, headers}}}

    @impl true
    def send_text(conn, _text), do: {:ok, conn}

    @impl true
    def close(_conn), do: :ok
  end

  defmodule FailingSendTransport do
    @moduledoc false
    @behaviour Aiur.ElevenLabs.Realtime.Transport

    @impl true
    def connect(url, headers) do
      send(Process.whereis(:realtime_test_observer), {:transport_connect, url, headers})
      {:ok, self()}
    end

    @impl true
    def send_text(_conn, _text), do: {:error, :closed}

    @impl true
    def close(_conn) do
      send(Process.whereis(:realtime_test_observer), :transport_close)
      :ok
    end
  end

  setup do
    Process.register(self(), :realtime_test_observer)
    :ok
  end

  describe "the credential" do
    test "travels in the xi-api-key request header and never in the connect URL" do
      {:ok, _session} = start_session()

      assert_receive {:transport_connect, url, headers}

      # The header carries it…
      assert {"xi-api-key", @api_key} in headers

      # …and the URL carries neither the key nor the query-parameter form of a
      # credential. ElevenLabs also accepts a single-use `token` parameter; that
      # is the browser answer and it still puts a credential in a URL, which is
      # the thing that ends up in logs and error messages.
      refute url =~ @api_key
      refute url =~ "token"

      assert url =~ "model_id=scribe_v2_realtime"
      assert url =~ "audio_format=pcm_16000"
      assert url =~ "language_code=eng"
      # Voice activity detection commits an utterance on a natural pause, which
      # is what settles text while the operator is still holding the key.
      assert url =~ "commit_strategy=vad"
    end

    test "never enters the session's process state" do
      {:ok, session} = start_session()
      assert_receive {:transport_connect, _url, _headers}

      rendered = inspect(:sys.get_state(session), limit: :infinity, printable_limit: :infinity, structs: false)

      refute rendered =~ @api_key
      refute rendered =~ "xi-api-key"
    end

    test "never reaches a log line or a failure reason when the session fails" do
      log =
        capture_log(fn ->
          {:ok, session} = start_session(transport: FailingTransport)
          ref = Process.monitor(session)

          # The connection failure is described generically, because the
          # underlying error can embed the request headers.
          assert_receive {:elevenlabs_error, "Speech-to-text connection failed"}
          assert_receive {:elevenlabs_closed}
          # The connect failure is immediate, so the session may already be gone
          # by the time the monitor is set; either way it does not linger.
          assert_receive {:DOWN, ^ref, :process, ^session, reason}
          assert reason in [:normal, :noproc]
        end)

      refute log =~ @api_key
    end

    test "an absent or blank key is reported as unconfigured rather than as a failure" do
      assert {:error, :unconfigured} = Realtime.start(owner: self(), api_key_fun: &__MODULE__.no_api_key/0)
      assert {:error, :unconfigured} = Realtime.start(owner: self(), api_key_fun: &__MODULE__.blank_api_key/0)
      refute_receive {:elevenlabs_error, _reason}, 20
    end
  end

  describe "readiness" do
    test "audio captured before session_started is queued and flushed in order on it" do
      {:ok, session} = started_session()

      Realtime.push(session, "AAAA")
      Realtime.push(session, "BBBB")
      refute_receive {:transport_send, _frame}, 20

      frame(session, %{"message_type" => "session_started"})

      assert %{"audio_base_64" => "AAAA", "commit" => false, "message_type" => "input_audio_chunk", "sample_rate" => 16_000} =
               assert_sent_frame()

      assert %{"audio_base_64" => "BBBB", "commit" => false} = assert_sent_frame()
    end

    test "audio after session_started is relayed verbatim with no transcode" do
      session = ready_session()

      Realtime.push(session, "Zm9vYmFy")
      assert %{"audio_base_64" => "Zm9vYmFy"} = assert_sent_frame()
    end
  end

  describe "transcripts" do
    test "committed_transcript is final and final_transcript is only a partial" do
      session = ready_session()

      frame(session, %{"message_type" => "partial_transcript", "text" => "ship the"})
      assert_receive {:elevenlabs_transcript, :partial, "ship the"}

      # Despite its name, `final_transcript` is still revisable. Treating it as
      # final duplicates phrases in the operator's outgoing message.
      frame(session, %{"message_type" => "final_transcript", "text" => "ship the fix"})
      assert_receive {:elevenlabs_transcript, :partial, "ship the fix"}

      frame(session, %{"message_type" => "committed_transcript", "text" => "ship the fix"})
      assert_receive {:elevenlabs_transcript, :final, "ship the fix"}
    end

    test "a malformed frame is ignored rather than ending a working session" do
      session = ready_session()

      send(session, {:elevenlabs_transport, :text, "{not json"})
      refute_receive {:elevenlabs_closed}, 20

      frame(session, %{"message_type" => "partial_transcript", "text" => "still here"})
      assert_receive {:elevenlabs_transcript, :partial, "still here"}
    end
  end

  describe "provider errors" do
    test "each documented error frame ends the session with an operator-readable reason" do
      # The named ones are rewritten for an operator; the rest carry the
      # provider's own detail, and fall back to a generic line when it has none.
      # The set is explicit rather than a `*_error` suffix heuristic, which would
      # silently miss `error`, `queue_overflow`, `quota_exceeded` and the rest
      # and leave a dead session looking merely quiet.
      for {type, detail, reason} <- [
            {"auth_error", "raw", "ElevenLabs rejected the API key"},
            {"quota_exceeded", "raw", "ElevenLabs quota exhausted"},
            {"rate_limited", "raw", "ElevenLabs rate limit reached"},
            {"commit_throttled", "raw", "ElevenLabs rate limit reached"},
            {"unaccepted_terms", "raw", "ElevenLabs terms not accepted for this account"},
            {"session_time_limit_exceeded", "raw", "ElevenLabs session time limit reached"},
            {"queue_overflow", nil, "Speech-to-text failed"},
            {"error", nil, "Speech-to-text failed"},
            {"invalid_request", "the request was rejected", "the request was rejected"}
          ] do
        session = ready_session()
        frame(session, %{"message_type" => type, "error" => detail})

        assert_receive {:elevenlabs_error, ^reason}
        assert_receive {:elevenlabs_closed}
        assert_receive :transport_close
      end
    end

    test "a transport failure mid-session is described generically" do
      session = ready_session()

      send(session, {:elevenlabs_transport, :error, %{headers: [{"xi-api-key", @api_key}]}})

      assert_receive {:elevenlabs_error, reason}
      refute reason =~ @api_key
      assert_receive {:elevenlabs_closed}
    end

    test "a failed audio send ends the session instead of silently dropping speech" do
      session = ready_session(transport: FailingSendTransport)

      Realtime.push(session, "AAAA")

      assert_receive {:elevenlabs_error, "Speech-to-text connection failed"}
      assert_receive {:elevenlabs_closed}
      assert_receive :transport_close
    end

    test "a failed commit send ends the session instead of reporting a completed utterance" do
      session = ready_session(transport: FailingSendTransport)

      Realtime.commit(session)

      assert_receive {:elevenlabs_error, "Speech-to-text connection failed"}
      assert_receive {:elevenlabs_closed}
      assert_receive :transport_close
    end

    test "a peer close ends the session without inventing an error" do
      session = ready_session()

      send(session, {:elevenlabs_transport, :closed})

      assert_receive {:elevenlabs_closed}
      refute_received {:elevenlabs_error, _reason}
    end
  end

  describe "the commit flush" do
    test "seals the utterance with an empty commit chunk and arms the deadline" do
      session = ready_session()
      Realtime.push(session, "AAAA")
      assert_sent_frame()

      Realtime.commit(session)

      # The documented way to seal the final utterance. Closing the socket
      # without it drops whatever the server had not yet committed — the tail of
      # what was just said.
      assert %{"audio_base_64" => "", "commit" => true} = assert_sent_frame()
      assert_receive {:flush_armed, 2_000}
    end

    test "closes as soon as the settled transcript arrives, without waiting out the deadline" do
      session = ready_session()
      Realtime.commit(session)
      assert_sent_frame()
      assert_receive {:flush_armed, _delay}

      frame(session, %{"message_type" => "committed_transcript", "text" => "the tail"})

      assert_receive {:elevenlabs_transcript, :final, "the tail"}
      assert_receive {:elevenlabs_closed}
    end

    test "closes on the deadline when the settled transcript never arrives" do
      session = ready_session()
      Realtime.commit(session)
      assert_sent_frame()
      assert_receive {:flush_armed, _delay}

      # Driven by hand: the deadline is a message, not an elapsed interval.
      send(session, :flush_deadline)

      assert_receive {:elevenlabs_closed}
      assert_receive :transport_close
    end

    test "audio pushed after the commit is dropped rather than reopening the utterance" do
      session = ready_session()
      Realtime.commit(session)
      assert_sent_frame()

      Realtime.push(session, "TOOLATE")
      refute_receive {:transport_send, _frame}, 20
    end

    test "a commit before the session is ready preserves queued audio and flushes after readiness" do
      {:ok, session} = started_session()
      Realtime.push(session, "AAAA")

      Realtime.commit(session)
      refute_receive {:elevenlabs_closed}, 20
      refute_receive {:transport_send, _frame}, 20

      frame(session, %{"message_type" => "session_started"})

      assert %{"audio_base_64" => "AAAA", "commit" => false} = assert_sent_frame()
      assert %{"audio_base_64" => "", "commit" => true} = assert_sent_frame()
      assert_receive {:flush_armed, 2_000}
    end
  end

  describe "readiness bounds" do
    test "fails a session that never becomes ready" do
      test_pid = self()
      {:ok, session} = start_session(ready_scheduler: fn delay_ms -> send(test_pid, {:ready_armed, delay_ms}) end)
      assert_receive {:transport_connect, _url, _headers}
      assert_receive {:ready_armed, 10_000}

      send(session, :ready_deadline)

      assert_receive {:elevenlabs_error, "Speech-to-text session did not become ready"}
      assert_receive {:elevenlabs_closed}
      assert_receive :transport_close
    end

    test "bounds audio queued before readiness" do
      {:ok, session} = start_session(max_backlog_bytes: 4)
      assert_receive {:transport_connect, _url, _headers}

      Realtime.push(session, "AAAAA")

      assert_receive {:elevenlabs_error, "Speech-to-text session did not become ready"}
      assert_receive {:elevenlabs_closed}
      assert_receive :transport_close
    end
  end

  test "the session stops with its owner so a connection cannot outlive the hold" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, session} = Realtime.start(session_opts(owner: owner))
    ref = Process.monitor(session)
    assert_receive {:transport_connect, _url, _headers}

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    assert_receive :transport_close
  end

  defp start_session(opts \\ []), do: Realtime.start(session_opts(opts))

  defp session_opts(opts) do
    test_pid = self()

    [
      owner: Keyword.get(opts, :owner, test_pid),
      api_key_fun: &__MODULE__.api_key/0,
      transport: Keyword.get(opts, :transport, FakeTransport),
      language_code: "eng",
      sample_rate: 16_000,
      scheduler: fn delay_ms -> send(test_pid, {:flush_armed, delay_ms}) end
    ]
    |> Keyword.merge(opts)
  end

  defp started_session do
    {:ok, session} = start_session()
    assert_receive {:transport_connect, _url, _headers}
    {:ok, session}
  end

  defp ready_session(opts \\ []) do
    {:ok, session} = started_session(opts)
    frame(session, %{"message_type" => "session_started"})
    session
  end

  defp started_session(opts) do
    {:ok, session} = start_session(opts)
    assert_receive {:transport_connect, _url, _headers}
    {:ok, session}
  end

  defp frame(session, message), do: send(session, {:elevenlabs_transport, :text, Jason.encode!(message)})

  defp assert_sent_frame do
    assert_receive {:transport_send, frame}
    Jason.decode!(frame)
  end
end
