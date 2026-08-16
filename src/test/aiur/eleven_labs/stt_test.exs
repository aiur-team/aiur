defmodule Aiur.ElevenLabs.STTTest do
  use ExUnit.Case, async: false

  alias Aiur.ElevenLabs.STT

  # A fake ElevenLabs realtime STT endpoint, served over a local Bandit
  # WebSocket. The mode selects the server behavior; every frame the client
  # sends is forwarded to the test process (registered as `:stt_fake_sink`) so
  # a test can assert on the exact audio bytes and commit flags that left the
  # session.
  defmodule FakeHandler do
    @behaviour WebSock

    @impl true
    def init(%{mode: mode} = state) do
      state = %{mode: mode, sink: Map.get(state, :sink, :stt_fake_sink), partial: Map.get(state, :partial, "hello")}

      if mode == :delayed_start, do: Process.send_after(self(), :start_session, 75)

      case open_frame(mode) do
        nil -> {:ok, state}
        frame -> {:push, {:text, Jason.encode!(frame)}, state}
      end
    end

    # WebSock delivers data frames as `{payload, [opcode: ...]}`.
    @impl true
    def handle_in({_data, [opcode: :text]}, %{mode: :close_on_audio} = state),
      do: {:stop, :normal, state}

    def handle_in({data, [opcode: :text]}, %{mode: :close_on_commit} = state) do
      record(state.sink, {:received, data})

      if commit_frame?(data) do
        {:stop, :normal, state}
      else
        {:ok, state}
      end
    end

    def handle_in({data, [opcode: :text]}, state) do
      record(state.sink, {:received, data})
      {:push, reply_for(state, data), state}
    end

    def handle_in(_frame, state), do: {:ok, state}

    @impl true
    def handle_info(:start_session, state),
      do: {:push, {:text, Jason.encode!(%{"message_type" => "session_started"})}, state}

    def handle_info(_message, state), do: {:ok, state}

    defp open_frame(:auth_error), do: %{"message_type" => "auth_error"}
    defp open_frame(:quota), do: %{"message_type" => "quota_exceeded"}
    defp open_frame(:error), do: %{"message_type" => "error", "error" => "boom"}
    defp open_frame(:upgrade_ok), do: nil
    defp open_frame(:delayed_start), do: nil
    defp open_frame(_mode), do: %{"message_type" => "session_started"}

    defp reply_for(%{mode: :auth_error}, _data), do: {:text, Jason.encode!(%{"message_type" => "auth_error"})}
    defp reply_for(%{mode: :error}, _data), do: {:text, Jason.encode!(%{"message_type" => "error", "error" => "boom"})}
    defp reply_for(%{mode: :quota}, _data), do: {:text, Jason.encode!(%{"message_type" => "quota_exceeded"})}

    defp reply_for(%{mode: :transcript, partial: partial}, data) do
      if commit_frame?(data) do
        {:text, Jason.encode!(%{"message_type" => "committed_transcript", "text" => partial <> " world"})}
      else
        {:text, Jason.encode!(%{"message_type" => "partial_transcript", "text" => partial})}
      end
    end

    defp reply_for(%{mode: :revisable_final}, data) do
      # `final_transcript` is still revisable and must surface as a partial;
      # only the committed frame is settled.
      if commit_frame?(data) do
        {:text, Jason.encode!(%{"message_type" => "committed_transcript", "text" => "settled text"})}
      else
        {:text, Jason.encode!(%{"message_type" => "final_transcript", "text" => "revisable text"})}
      end
    end

    defp reply_for(%{mode: :malformed}, _data), do: {:text, "not-json"}

    defp reply_for(%{mode: :silent}, _data), do: {:text, Jason.encode!(%{"message_type" => "some_unknown_frame"})}
    defp reply_for(%{mode: :delayed_start}, _data), do: {:text, Jason.encode!(%{"message_type" => "some_unknown_frame"})}

    defp commit_frame?(data) do
      frame = Jason.decode!(data)
      Map.get(frame, "commit", false) == true
    end

    defp record(nil, _event), do: :ok

    defp record(name, event) do
      case Process.whereis(name) do
        nil -> :ok
        pid -> send(pid, event)
      end
    end
  end

  defmodule FakePlug do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      if Keyword.fetch!(opts, :mode) == :capture_request do
        send(Process.whereis(:stt_fake_sink), {
          :stt_request,
          conn.request_path,
          conn.query_string,
          Plug.Conn.get_req_header(conn, "xi-api-key")
        })
      end

      WebSockAdapter.upgrade(
        conn,
        FakeHandler,
        %{mode: Keyword.fetch!(opts, :mode), partial: Keyword.get(opts, :partial, "hello")},
        []
      )
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:websockex)
    {:ok, _} = Application.ensure_all_started(:websock)
    true = Process.register(self(), :stt_fake_sink)

    on_exit(fn ->
      if Process.whereis(:stt_fake_sink) == self() do
        Process.unregister(:stt_fake_sink)
      end
    end)

    :ok
  end

  test "keeps the provider credential in a request header instead of the URL" do
    server = start_fake(mode: :capture_request)
    session = start_session(server, [])

    assert_receive {:stt_request, "/v1/speech-to-text/realtime", query, ["test-key"]}, 2_000
    refute query =~ "test-key"
    assert query =~ "model_id=scribe_v2_realtime"
    STT.stop(session)
  end

  test "queues pre-readiness audio and transcribes partials then a settled final" do
    server = start_fake(mode: :transcript, partial: "hello")
    session = start_session(server, [])

    first_pcm = :crypto.strong_rand_bytes(1_000)
    second_pcm = :crypto.strong_rand_bytes(1_000)
    STT.push(session, first_pcm)
    STT.push(session, second_pcm)

    assert_receive {:stt_transcript, :partial, "hello"}, 2_000
    # Both chunks survive the pre-readiness queue and are delivered in order.
    frames = assert_received_frames(2)
    assert Enum.map(frames, &Base.decode64!(Map.fetch!(&1, "audio_base_64"))) == [first_pcm, second_pcm]

    STT.commit(session)
    assert_receive {:stt_transcript, :final, "hello world"}, 2_000
    assert_received_commit()
    assert_session_stopped(session)
  end

  test "treats a revisable final_transcript as a partial and settles on committed" do
    server = start_fake(mode: :revisable_final)
    session = start_session(server, [])

    STT.push(session, <<0, 0, 1, 1>>)
    assert_receive {:stt_transcript, :partial, "revisable text"}, 2_000

    STT.commit(session)
    assert_receive {:stt_transcript, :final, "settled text"}, 2_000
    assert_received_commit()
  end

  test "reports an auth error and stops the session" do
    server = start_fake(mode: :auth_error)
    session = start_session(server, [])

    assert_receive {:stt_error, "ElevenLabs rejected the API key"}, 2_000

    STT.push(session, <<1, 2, 3, 4>>)
    refute_receive {:stt_transcript, _, _}, 150
  end

  test "maps a quota frame to an operator-readable reason" do
    server = start_fake(mode: :quota)
    _session = start_session(server, [])

    assert_receive {:stt_error, "ElevenLabs quota exhausted"}, 2_000
  end

  test "reports a generic error frame without leaking the key" do
    server = start_fake(mode: :error)
    _session = start_session(server, [])

    assert_receive {:stt_error, "Speech-to-text failed"}, 2_000
  end

  test "ignores malformed frames and keeps the session alive" do
    server = start_fake(mode: :malformed)
    session = start_session(server, [])

    STT.push(session, <<1, 1, 1, 1>>)
    STT.push(session, <<2, 2, 2, 2>>)

    # The malformed frame must not tear the session down; both chunks still
    # reach the provider.
    assert_received_frames(2)
  end

  test "empty commit before session readiness sends nothing and stops" do
    server = start_fake(mode: :upgrade_ok)
    session = start_session(server, [])

    # Nothing was captured, so there is no utterance to wait for or commit.
    STT.commit(session)

    assert_receive {:stt_stopped, :ok}, 2_000
    refute_received_frames()
    assert_session_stopped(session)
  end

  test "commit before session readiness flushes the queued utterance" do
    server = start_fake(mode: :delayed_start)
    session = start_session(server, [])
    pcm = <<1, 2, 3, 4>>

    STT.push(session, pcm)
    STT.commit(session)

    frames = assert_received_frames(2)
    assert Base.decode64!(Map.fetch!(hd(frames), "audio_base_64")) == pcm
    assert Enum.any?(frames, &(Map.get(&1, "commit") == true))
  end

  test "provider close while recording is reported as an error" do
    server = start_fake(mode: :close_on_audio)
    session = start_session(server, [])

    STT.push(session, <<1, 2, 3, 4>>)

    assert_receive {:stt_error, "Speech-to-text connection closed"}, 2_000
    assert_session_stopped(session)
  end

  test "provider close before the committed transcript is reported as an error" do
    server = start_fake(mode: :close_on_commit)
    session = start_session(server, [])

    STT.push(session, <<1, 2, 3, 4>>)
    assert_received_frames(1)
    STT.commit(session)

    assert_receive {:stt_error, "Speech-to-text connection closed before the final transcript arrived"}, 2_000
    refute_receive {:stt_stopped, :ok}, 100
    assert_session_stopped(session)
  end

  test "bounds audio queued while the provider never starts the session" do
    server = start_fake(mode: :upgrade_ok)
    session = start_session(server, connect_timeout_ms: 2_000)

    STT.push(session, :binary.copy(<<1>>, 320_001))

    assert_receive {:stt_error, "Speech-to-text session did not become ready"}, 2_000
    refute_received_frames()
  end

  test "times out when the websocket upgrades but no session starts" do
    server = start_fake(mode: :upgrade_ok)
    session = start_session(server, connect_timeout_ms: 50)

    assert_receive {:stt_error, "Speech-to-text session did not become ready"}, 2_000
    assert_session_stopped(session)
  end

  test "a missing websocket upgrade response times out and stops" do
    server = start_blackhole()
    on_exit(fn -> send(server.pid, :stop) end)
    session = start_session(server, connect_timeout_ms: 50)

    assert_receive {:stt_error, "Speech-to-text connection failed: %WebSockex.ConnError{original: :timeout}"}, 2_000
    assert_session_stopped(session)
  end

  test "a final transcript timeout is an error rather than a successful stop" do
    server = start_fake(mode: :silent)
    session = start_session(server, flush_timeout_ms: 50)

    STT.push(session, <<1, 2, 3, 4>>)
    assert_received_frames(1)
    STT.commit(session)

    assert_receive {:stt_error, "Speech-to-text final transcript timed out"}, 2_000
    refute_receive {:stt_stopped, :ok}, 100
    assert_session_stopped(session)
  end

  test "unknown provider frames are ignored and the session stays live" do
    server = start_fake(mode: :silent)
    session = start_session(server, [])

    STT.push(session, <<7, 7, 7, 7>>)

    # No transcript, no error; the session is still usable.
    refute_receive {:stt_transcript, _, _}, 150
    refute_receive {:stt_error, _}, 150
  end

  # --- helpers -------------------------------------------------------------

  defp start_fake(opts) do
    port = free_port()

    {:ok, pid} =
      Bandit.start_link(plug: {FakePlug, opts}, ip: {127, 0, 0, 1}, port: port)

    %{port: port, pid: pid}
  end

  defp start_blackhole do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false, reuseaddr: true)
    {:ok, port} = :inet.port(listen)

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)

        receive do
          :stop -> :ok
        after
          3_000 -> :ok
        end

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)

    %{port: port, pid: pid}
  end

  defp start_session(server, opts) do
    base_url = "ws://127.0.0.1:#{server.port}/v1/speech-to-text/realtime"

    {:ok, pid} =
      STT.start_link([owner: self(), api_key: "test-key", language_code: "eng", base_url: base_url, flush_timeout_ms: 300] ++ opts)

    pid
  end

  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false, reuseaddr: true)
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end

  # Wait (bounded) until `count` frames have been recorded by the fake server,
  # then return the accumulated frames; the caller asserts on them.
  defp assert_received_frames(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:received, data}, 2_000
      Jason.decode!(data)
    end)
  end

  defp refute_received_frames do
    refute_receive {:received, _data}, 250
  end

  defp assert_received_commit do
    assert_receive {:received, data}, 2_000
    frame = Jason.decode!(data)

    if Map.get(frame, "commit") == true do
      :ok
    else
      assert_received_commit()
    end
  end

  defp assert_session_stopped(session) do
    monitor = Process.monitor(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, reason}, 2_000
    assert reason in [:normal, :noproc]
    refute Process.alive?(session)
  end
end
