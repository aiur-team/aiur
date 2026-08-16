defmodule AiurWeb.VoiceChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest
  import Plug.Conn, only: [get_session: 2, put_req_header: 3]
  import Plug.Test

  alias AiurWeb.{Endpoint, FinancialDataAccess, VoiceSessionLimiter, VoiceSocket}
  alias AiurWeb.FinancialDataAccess.Generation

  @endpoint Endpoint

  # A fake STT session the channel drives. It records pushes/commits and can
  # push transcript and error frames back to the channel process, exactly the
  # messages `Aiur.ElevenLabs.STT` would send its owner.
  defmodule FakeSTT do
    use GenServer

    # Unlinked on purpose: the channel's terminate stops the session, and the
    # test needs to query `stopped?` after the channel has exited without the
    # session dying with it first.
    def start(opts), do: GenServer.start(__MODULE__, opts)

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

    def push(pid, pcm), do: GenServer.cast(pid, {:push, pcm})
    def commit(pid), do: GenServer.cast(pid, :commit)
    def stop(pid), do: GenServer.cast(pid, :stop)

    def transcript(pid, kind, text), do: GenServer.call(pid, {:transcript, kind, text})
    def error(pid, reason), do: GenServer.call(pid, {:error, reason})

    def pushes(pid), do: GenServer.call(pid, :pushes)
    def committed?(pid), do: GenServer.call(pid, :committed?)
    def stopped?(pid), do: GenServer.call(pid, :stopped?)

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

    def handle_call({:transcript, kind, text}, _from, state) do
      send(state.channel, {:stt_transcript, kind, text})
      {:reply, :ok, state}
    end

    def handle_call({:error, reason}, _from, state) do
      send(state.channel, {:stt_error, reason})
      {:reply, :ok, state}
    end

    def handle_call(:pushes, _from, state), do: {:reply, Enum.reverse(state.pushes), state}
    def handle_call(:committed?, _from, state), do: {:reply, state.committed?, state}
    def handle_call(:stopped?, _from, state), do: {:reply, state.stopped?, state}
  end

  setup do
    # The channel process is linked to this test process; trap its exit so the
    # leave/disconnect path can be asserted without the link crashing the test.
    Process.flag(:trap_exit, true)

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
        dashboard_writable: true,
        voice_stt_start_fun: fake_stt_start_fun()
      )

    Application.put_env(:aiur, Endpoint, config)

    if is_nil(Process.whereis(Generation)), do: start_supervised!(Generation)
    if is_nil(Process.whereis(VoiceSessionLimiter)), do: start_supervised!(VoiceSessionLimiter)
    if is_nil(Process.whereis(Aiur.PubSub)), do: start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})

    if is_nil(Process.whereis(Endpoint)) do
      start_supervised!({Endpoint, []})
    else
      Endpoint.config_change(config, [])
    end

    on_exit(fn ->
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

    assert {:ok, trusted} =
             VoiceSocket.connect(%{}, socket(VoiceSocket, "trusted", %{}), %{session: authenticated_session()})

    assert is_binary(trusted.assigns.voice_authority.configuration_generation)
    assert is_binary(trusted.assigns.voice_authority.connection_generation)
  end

  test "voice socket remains disabled for a read-only dashboard" do
    config = Keyword.put(Application.get_env(:aiur, Endpoint), :dashboard_writable, false)
    Application.put_env(:aiur, Endpoint, config)
    :ok = Endpoint.config_change([{Endpoint, config}], [])

    assert :error =
             VoiceSocket.connect(%{}, socket(VoiceSocket, "trusted", %{}), %{session: authenticated_session()})
  end

  test "unconfigured dictation explains in the rejected join" do
    # Drop the injected fake from the live endpoint config. `config_change`
    # expects `{Endpoint, full_config}` so the absent key is deleted from the
    # endpoint's cached ETS config without wiping the other keys.
    config = Keyword.delete(Application.get_env(:aiur, Endpoint), :voice_stt_start_fun)
    Application.put_env(:aiur, Endpoint, config)
    :ok = Endpoint.config_change([{Endpoint, config}], [])

    {socket, _client} = voice_socket()

    assert {:error, %{reason: reason}} = subscribe_and_join(socket, "voice:dictation")
    assert reason =~ "not configured"
  end

  test "rejects a credential rotation between socket connect and channel join" do
    assert {:ok, trusted} =
             VoiceSocket.connect(%{}, socket(VoiceSocket, "trusted", %{}), %{session: authenticated_session()})

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
    assert_receive {:fake_stt_push, ^fake, ^first}, 2_000
    assert_receive {:fake_stt_push, ^fake, ^second}, 2_000
    assert FakeSTT.pushes(fake) == [first, second]

    push(joined, "stop", %{})
    assert_receive {:fake_stt_commit, ^fake}, 2_000
    assert FakeSTT.committed?(fake)
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
    assert_receive {:fake_stt_push, ^fake, ^tiny}, 2_000
    assert_push("error", %{"reason" => "Audio chunk is too large."})
    assert_push("error", %{"reason" => "Audio chunk is too large."})
    refute_receive {:fake_stt_push, ^fake, _pcm}, 250
    assert FakeSTT.pushes(fake) == [tiny]
  end

  test "reports malformed audio payloads" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    fake = joined.assigns.stt.pid
    tiny = <<9, 9, 9>>
    push(joined, "audio", %{"data" => Base.encode64(tiny)})
    push(joined, "audio", %{"data" => "not-base64!!!"})
    push(joined, "audio", %{"data" => 42})
    assert_receive {:fake_stt_push, ^fake, ^tiny}, 2_000
    assert_push("error", %{"reason" => "Audio chunk encoding is invalid."})
    assert_push("error", %{"reason" => "Audio chunk encoding is invalid."})
    refute_receive {:fake_stt_push, ^fake, _pcm}, 250
    assert FakeSTT.pushes(fake) == [tiny]
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
    assert_receive {:fake_stt_push, ^fake, ^first}, 2_000

    push(joined, "audio", %{"data" => Base.encode64(<<4, 5, 6>>)})
    assert_push("error", %{"reason" => "Dictation reached the five-minute limit. Review the text and start again."})
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 2_000
  end

  test "relays transcript frames from the session to the client" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    fake = joined.assigns.stt.pid
    :ok = FakeSTT.transcript(fake, :partial, "hello ")
    assert_push("transcript", %{"kind" => "partial", "text" => "hello "})

    :ok = FakeSTT.transcript(fake, :final, "hello world")
    assert_push("transcript", %{"kind" => "final", "text" => "hello world"})
  end

  test "relays a session error to the client" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    fake = joined.assigns.stt.pid
    :ok = FakeSTT.error(fake, "ElevenLabs rejected the API key")
    assert_push("error", %{"reason" => "ElevenLabs rejected the API key"})
  end

  test "stops the stt session when the channel leaves" do
    {socket, _client} = voice_socket()
    assert {:ok, _reply, joined} = subscribe_and_join(socket, "voice:dictation")

    fake = joined.assigns.stt.pid
    refute FakeSTT.stopped?(fake)

    leave(joined)

    # The channel's terminate calls STT.stop/1 on the session; the fake
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

  defp authenticated_session do
    conn =
      conn(:get, "/")
      |> Plug.Test.init_test_session(%{})
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> FinancialDataAccess.call([])
      |> FinancialDataAccess.call(:persist_session)

    %{FinancialDataAccess.session_key() => get_session(conn, FinancialDataAccess.session_key())}
  end

  defp fake_stt_start_fun do
    observer = self()

    fn socket ->
      {:ok, pid} = FakeSTT.start(channel: socket.channel_pid, observer: observer)
      {:ok, %{pid: pid}}
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
