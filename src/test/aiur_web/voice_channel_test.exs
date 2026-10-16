Code.require_file("fixtures/voice_provider.exs", __DIR__)

defmodule AiurWeb.VoiceChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest
  import Plug.Conn, only: [get_session: 2, put_req_header: 3, send_resp: 3]
  import Plug.Test

  alias AiurWeb.{Endpoint, FinancialDataAccess, VoiceSessionLimiter, VoiceSocket}
  alias AiurWeb.FinancialDataAccess.Generation

  alias __MODULE__.{FakeSTT, FakeVoiceProvider, UnconfiguredProvider}

  @endpoint Endpoint

  setup do
    # The channel process is linked to this test process; trap its exit so the
    # leave/disconnect path can be asserted without the link crashing the test.
    Process.flag(:trap_exit, true)
    {:ok, _started} = Application.ensure_all_started(:phoenix_pubsub)

    previous_provider = Application.fetch_env(:aiur, :voice_provider)
    previous_fake = Application.fetch_env(:aiur, FakeVoiceProvider)
    Application.put_env(:aiur, :voice_provider, FakeVoiceProvider)
    Application.put_env(:aiur, FakeVoiceProvider, observer: self())

    previous_endpoint = Application.get_env(:aiur, Endpoint)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    config =
      previous_endpoint
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_auth_required: true,
        dashboard_writable: true
      )

    Application.put_env(:aiur, Endpoint, config)

    if is_nil(Process.whereis(Generation)), do: start_supervised!(Generation)
    if is_nil(Process.whereis(VoiceSessionLimiter)), do: start_supervised!(VoiceSessionLimiter)
    :ok = Aiur.TestSupport.ensure_pubsub_running()

    Aiur.TestSupport.start_owned_endpoint!()
    Endpoint.config_change([{Endpoint, config}], [])

    on_exit(fn ->
      restore_app_env(:voice_provider, previous_provider)
      restore_app_env(FakeVoiceProvider, previous_fake)
      Application.put_env(:aiur, Endpoint, previous_endpoint)
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)

      if Process.whereis(Endpoint) do
        :ok = Endpoint.config_change([{Endpoint, previous_endpoint || []}], [])
      end
    end)

    :ok
  end

  test "voice socket requires the dashboard session proof to connect" do
    assert :error = VoiceSocket.connect(%{}, socket(VoiceSocket, "untrusted", %{}), %{})

    assert :error =
             VoiceSocket.connect(%{}, socket(VoiceSocket, "untrusted", %{}), %{session: %{}})

    {session, csrf_token} = authenticated_session_with_csrf()

    assert :error =
             VoiceSocket.connect(%{}, socket(VoiceSocket, "untrusted", %{}), %{session: session})

    assert :error =
             VoiceSocket.connect(%{"_csrf_token" => "invalid"}, socket(VoiceSocket, "untrusted", %{}), %{
               session: session
             })

    assert {:ok, trusted} =
             VoiceSocket.connect(%{"_csrf_token" => csrf_token}, socket(VoiceSocket, "trusted", %{}), %{session: session})

    assert is_binary(trusted.assigns.voice_authority.configuration_generation)
    assert is_binary(trusted.assigns.voice_authority.connection_generation)
  end

  test "voice socket remains disabled for a read-only dashboard" do
    config = Keyword.put(Application.get_env(:aiur, Endpoint), :dashboard_writable, false)
    Application.put_env(:aiur, Endpoint, config)
    :ok = Endpoint.config_change([{Endpoint, config}], [])

    {session, csrf_token} = authenticated_session_with_csrf()

    assert :error =
             VoiceSocket.connect(%{"_csrf_token" => csrf_token}, socket(VoiceSocket, "trusted", %{}), %{session: session})
  end

  test "unconfigured dictation explains in the rejected join" do
    Application.put_env(:aiur, :voice_provider, UnconfiguredProvider)

    {socket, _client} = voice_socket()

    assert {:error, %{reason: reason}} = subscribe_and_join(socket, "voice:dictation")
    assert reason =~ "not configured"
  end

  test "dictation without a voice provider is refused and releases its lease" do
    # Keep the failed join owner alive so its monitor cannot hide a leaked lease.
    Application.put_env(:aiur, :voice_provider, nil)
    {socket, _client} = voice_socket()

    assert {:error, %{reason: "Speech-to-text could not start. Check the daemon log and retry."}} =
             AiurWeb.VoiceChannel.join("voice:dictation", %{}, socket)

    Application.put_env(:aiur, :voice_provider, FakeVoiceProvider)

    for _ <- 1..2 do
      {socket, _client} = voice_socket()
      assert {:ok, _reply, _joined} = subscribe_and_join(socket, "voice:dictation")
    end
  end

  test "rejects a credential rotation between socket connect and channel join" do
    {session, csrf_token} = authenticated_session_with_csrf()

    assert {:ok, trusted} =
             VoiceSocket.connect(%{"_csrf_token" => csrf_token}, socket(VoiceSocket, "trusted", %{}), %{session: session})

    :ok = Generation.invalidate()

    assert {:error, %{reason: reason}} = subscribe_and_join(trusted, "voice:dictation")
    assert reason =~ "authentication changed"
  end

  test "pushes audio chunks into the stt session and commits on stop" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    fake = joined.assigns.stt.pid
    first = :crypto.strong_rand_bytes(100)
    second = :crypto.strong_rand_bytes(100)

    refute_push("error", _, 50)
    push(joined, "audio", %{"data" => Base.encode64(first)})
    push(joined, "audio", %{"data" => Base.encode64(second)})
    assert_receive {:fake_stt_push, ^fake, first_encoded}, 2_000
    assert_receive {:fake_stt_push, ^fake, second_encoded}, 2_000
    assert Base.decode64!(first_encoded) == first
    assert Base.decode64!(second_encoded) == second
    assert Enum.map(FakeSTT.pushes(fake), &Base.decode64!/1) == [first, second]

    push(joined, "stop", %{})
    assert_receive {:fake_stt_commit, ^fake}, 2_000
    assert FakeSTT.committed?(fake)
  end

  test "conversation mode streams an agent reply as browser PCM" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:conversation")
    send(joined.channel_pid, {:voice_closed})
    await_channel(joined)
    assert_push("stopped", %{})

    push(joined, "speak", %{"text" => "Agent reply"})

    assert_receive {:fake_tts_request, "Agent reply"}, 1000
    assert_push("audio", %{"data" => encoded, "format" => "pcm_44100"})
    assert Base.decode64!(encoded) == <<1, 2, 3, 4>>
    assert_push("audio_done", %{})

    push(joined, "speak", %{"text" => "charge twice"})
    assert_push("audio_error", %{"reason" => "A voice reply was already requested for this turn."})
    refute_receive {:fake_tts_request, "charge twice"}, 100
  end

  test "conversation mode reports a text-to-speech startup failure" do
    Application.put_env(:aiur, FakeVoiceProvider, observer: self(), speech: :unavailable)

    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:conversation")
    send(joined.channel_pid, {:voice_closed})
    await_channel(joined)
    assert_push("stopped", %{})

    push(joined, "speak", %{"text" => "Agent reply"})

    assert_push("audio_error", %{"reason" => "Voice playback could not start."})
    refute_push("audio", _payload, 100)
  end

  test "dictation mode cannot request speech playback" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    push(joined, "speak", %{"text" => "must not speak"})
    refute_receive {:fake_tts_request, _text}, 100
    refute_push("audio", _payload, 100)
  end

  test "bounds concurrent text-to-speech streams while conversations await replies" do
    Application.put_env(:aiur, FakeVoiceProvider, observer: self(), speech: :blocking)

    joined =
      for index <- 1..3 do
        {socket, _client} = voice_socket()
        assert {:ok, _reply, channel} = subscribe_and_join(socket, "voice:conversation")
        send(channel.channel_pid, {:voice_closed})
        await_channel(channel)
        assert_push("stopped", %{})
        {index, channel}
      end

    for {index, channel} <- Enum.take(joined, 2) do
      push(channel, "speak", %{"text" => "reply #{index}"})
      assert_receive {:blocking_tts_started, "reply " <> _index}, 1000
    end

    {_index, third} = List.last(joined)
    push(third, "speak", %{"text" => "reply 3"})
    assert_push("audio_error", %{"reason" => "Too many dashboard voice replies are active. Try again shortly."})
    refute_receive {:blocking_tts_started, "reply 3"}, 100
  end

  test "bounds concurrent sessions for one authenticated browser" do
    {first_socket, _client} = voice_socket()
    {second_socket, _client} = voice_socket()
    {third_socket, _client} = voice_socket()

    assert {:ok, _reply, _first} = subscribe_and_join(first_socket, "voice:dictation")
    assert {:ok, _reply, _second} = subscribe_and_join(second_socket, "voice:dictation")

    assert {:error, %{reason: reason}} = subscribe_and_join(third_socket, "voice:dictation")
    assert reason =~ "Too many dashboard dictation sessions"
  end

  test "releases transcription capacity while conversation mode waits for the agent" do
    {first_socket, _client} = voice_socket()
    {second_socket, _client} = voice_socket()
    {third_socket, _client} = voice_socket()

    assert {:ok, _reply, first} = subscribe_and_join(first_socket, "voice:conversation")
    assert {:ok, _reply, _second} = subscribe_and_join(second_socket, "voice:conversation")
    assert {:error, %{reason: reason}} = subscribe_and_join(third_socket, "voice:conversation")
    assert reason =~ "Too many dashboard dictation sessions"

    send(first.channel_pid, {:voice_closed})
    await_channel(first)
    assert_push("stopped", %{})

    assert {:ok, _reply, _third} = subscribe_and_join(third_socket, "voice:conversation")
  end

  test "rejects oversize audio chunks before they reach the session" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    fake = joined.assigns.stt.pid
    tiny = <<1, 2, 3>>
    huge = :binary.copy(<<1>>, 300_000)

    # A valid chunk proves the relay works; the oversize chunk after it must
    # never reach the session.
    push(joined, "audio", %{"data" => Base.encode64(tiny)})
    push(joined, "audio", %{"data" => Base.encode64(huge)})
    push(joined, "audio", %{"data" => :binary.copy("A", 400_000)})
    assert_receive {:fake_stt_push, ^fake, encoded}, 2_000
    assert Base.decode64!(encoded) == tiny
    assert_push("error", %{"reason" => "Audio chunk is too large."})
    assert_push("error", %{"reason" => "Audio chunk is too large."})
    refute_receive {:fake_stt_push, ^fake, _pcm}, 250
    assert Enum.map(FakeSTT.pushes(fake), &Base.decode64!/1) == [tiny]
  end

  test "reports malformed audio payloads" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    fake = joined.assigns.stt.pid
    tiny = <<9, 9, 9>>
    push(joined, "audio", %{"data" => Base.encode64(tiny)})
    push(joined, "audio", %{"data" => "not-base64!!!"})
    push(joined, "audio", %{"data" => 42})
    assert_receive {:fake_stt_push, ^fake, encoded}, 2_000
    assert Base.decode64!(encoded) == tiny
    assert_push("error", %{"reason" => "Audio chunk encoding is invalid."})
    assert_push("error", %{"reason" => "Audio chunk encoding is invalid."})
    refute_receive {:fake_stt_push, ^fake, _pcm}, 250
    assert Enum.map(FakeSTT.pushes(fake), &Base.decode64!/1) == [tiny]
  end

  test "closes a dictation that exceeds the session audio budget" do
    config = Keyword.put(Application.get_env(:aiur, Endpoint), :voice_max_session_audio_bytes, 4)
    Application.put_env(:aiur, Endpoint, config)
    :ok = Endpoint.config_change([{Endpoint, config}], [])

    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    fake = joined.assigns.stt.pid
    monitor = Process.monitor(joined.channel_pid)
    first = <<1, 2, 3>>
    push(joined, "audio", %{"data" => Base.encode64(first)})
    assert_receive {:fake_stt_push, ^fake, encoded}, 2_000
    assert Base.decode64!(encoded) == first

    push(joined, "audio", %{"data" => Base.encode64(<<4, 5, 6>>)})
    assert_push("error", %{"reason" => "Dictation reached the five-minute limit. Review the text and start again."})
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 2_000
  end

  test "relays transcript frames from the session to the client" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    fake = joined.assigns.stt.pid
    :ok = FakeSTT.transcript(fake, :partial, "hello ")
    await_channel(joined)
    assert_push("transcript", %{"kind" => "partial", "text" => "hello "})

    :ok = FakeSTT.transcript(fake, :final, "hello world")
    await_channel(joined)
    assert_push("transcript", %{"kind" => "final", "text" => "hello world"})
  end

  test "relays a session error to the client" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    fake = joined.assigns.stt.pid
    :ok = FakeSTT.error(fake, "ElevenLabs rejected the API key")
    await_channel(joined)
    assert_push("error", %{"reason" => "ElevenLabs rejected the API key"})
  end

  test "stops the stt session when the channel leaves" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    fake = joined.assigns.stt.pid
    refute FakeSTT.stopped?(fake)

    leave(joined)

    # The channel's terminate closes the shared realtime session; the fake
    # records the cast before anything tears it down.
    assert_receive {:fake_stt_stop, ^fake}, 2_000
    assert FakeSTT.stopped?(fake)
  end

  test "stops the channel when dashboard credentials rotate" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")
    monitor = Process.monitor(joined.channel_pid)

    send(joined.channel_pid, {FinancialDataAccess, :configuration_changed, "replacement-generation"})

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 1_000
  end

  # --- helpers -------------------------------------------------------------

  # A frame sent before this (by the test, or by the fake before it replied) is
  # queued ahead of the sys call: once it returns, the channel has pushed to us.
  defp await_channel(joined), do: :sys.get_state(joined.channel_pid)

  defp voice_socket do
    {:ok, generation} = FinancialDataAccess.current_configuration_generation()

    socket =
      socket(VoiceSocket, "voice-client", %{
        voice_authority: %{
          configuration_generation: generation,
          connection_generation: "test-connection-generation"
        }
      })

    {socket, nil}
  end

  defp authenticated_session_with_csrf do
    conn =
      conn(:get, "/")
      |> Plug.Test.init_test_session(%{})
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> FinancialDataAccess.call([])
      |> FinancialDataAccess.call(:persist_session)
      |> Plug.CSRFProtection.call(Plug.CSRFProtection.init([]))

    csrf_token = Plug.CSRFProtection.get_csrf_token()
    conn = send_resp(conn, 200, "ok")

    {%{
       FinancialDataAccess.session_key() => get_session(conn, FinancialDataAccess.session_key()),
       "_csrf_token" => get_session(conn, "_csrf_token")
     }, csrf_token}
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:aiur, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:aiur, key)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
