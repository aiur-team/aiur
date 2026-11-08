defmodule Aiur.ElevenLabs.RealtimeTest do
  @moduledoc """
  Aiur's binding of the extracted `voice_transcribe` package.

  The protocol itself — readiness, backlog, commit flush, provider errors,
  credential non-retention — is covered by the package's own suite, which runs
  standalone in the `voice-transcribe-standalone` CI job. What is left to prove
  here is the seam: that Aiur supplies its configured credential and language,
  that a caller can still inject its own, and that the `Aiur.Voice.Transcriber`
  callbacks reach the package session.
  """

  use ExUnit.Case, async: false

  alias Aiur.ElevenLabs.Realtime

  @injected_key "sk-injected-adapter-key"

  defmodule FakeTransport do
    @moduledoc false
    @behaviour VoiceTranscribe.Scribe.Transport

    @impl true
    def connect(url, headers) do
      [observer | _] = Process.get(:"$ancestors")
      send(observer, {:transport_connect, url, headers})
      {:ok, observer}
    end

    @impl true
    def send_text(conn, text) do
      send(conn, {:transport_send, text})
      {:ok, conn}
    end

    @impl true
    def close(conn) do
      send(conn, :transport_close)
      :ok
    end
  end

  test "a caller's injected reader and language win over Aiur's configuration" do
    {:ok, session} =
      Realtime.start(
        owner: self(),
        api_key_fun: fn -> @injected_key end,
        language_code: "deu",
        transport: FakeTransport
      )

    assert_receive {:transport_connect, url, headers}, 1000
    assert {"xi-api-key", @injected_key} in headers
    assert url =~ "language_code=deu"
    refute url =~ @injected_key

    Realtime.stop(session)
    assert_receive :transport_close, 1000
  end

  test "the Aiur.Voice.Transcriber callbacks reach the package session" do
    {:ok, session} =
      Realtime.start(owner: self(), api_key_fun: fn -> @injected_key end, transport: FakeTransport)

    assert_receive {:transport_connect, _url, _headers}, 1000

    # `session_started` opens the readiness gate, so the pushed frame is relayed
    # rather than queued — which is what proves `push/2` reached the session.
    send(session, {:scribe_transport, :text, Jason.encode!(%{"message_type" => "session_started"})})

    Realtime.push(session, "Zm9vYmFy")
    assert_receive {:transport_send, frame}, 1000
    assert %{"audio_base_64" => "Zm9vYmFy"} = Jason.decode!(frame)

    Realtime.commit(session)
    assert_receive {:transport_send, commit_frame}, 1000
    assert %{"audio_base_64" => "", "commit" => true} = Jason.decode!(commit_frame)

    Realtime.stop(session)
    assert_receive :transport_close, 1000
  end

  test "Aiur's configured credential and language are the defaults" do
    configured_key = Aiur.Config.elevenlabs_api_key()
    configured_language = Aiur.Config.elevenlabs_language_code()

    if is_binary(configured_key) and String.trim(configured_key) != "" do
      {:ok, session} = Realtime.start(owner: self(), transport: FakeTransport)

      assert_receive {:transport_connect, url, headers}, 1000
      assert {"xi-api-key", configured_key} in headers
      assert url =~ "language_code=#{configured_language}"

      Realtime.stop(session)
    else
      # No key configured: the adapter must report that plainly rather than
      # starting a session that immediately fails.
      assert {:error, :unconfigured} = Realtime.start(owner: self(), transport: FakeTransport)
    end
  end
end
