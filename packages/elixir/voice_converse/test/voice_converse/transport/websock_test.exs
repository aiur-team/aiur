if Code.ensure_loaded?(VoiceConverse.Transport.WebSock) do
  defmodule VoiceConverse.Transport.WebSockTestIssuer do
    @behaviour VoiceConverse.Ports.TokenIssuer

    @impl true
    def issue(_scope, _opts), do: {:error, :unsupported}

    @impl true
    def verify("good", "converse", _opts), do: {:ok, %{}}
    def verify(_token, _scope, _opts), do: {:error, :invalid}
  end

  defmodule VoiceConverse.Transport.WebSockTest do
    use ExUnit.Case, async: false

    alias VoiceConverse.{Config, Drafts, Events, SessionRegistry, TranscriptStore}
    alias VoiceConverse.Testing.{FakeAgentChannel, FakeBriefingSource, FakeProvider, StaticCredentials}
    alias VoiceConverse.Transport.WebSock
    alias VoiceConverse.Transport.WebSock.Socket

    setup do
      root = Path.join(System.tmp_dir!(), "voice_converse_websock_#{System.unique_integer([:positive])}")
      name = Module.concat([VoiceConverse, "WebSockTest#{System.unique_integer([:positive])}"])
      File.mkdir_p!(root)
      File.chmod!(root, 0o700)
      StaticCredentials.put(%{fake: "test-secret"})
      on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)
      %{root: root, name: name}
    end

    test "rejects missing or invalid tokens before a session can start" do
      assert not WebSock.authorized?(Plug.Test.conn(:get, "/"), token_issuer: VoiceConverse.Transport.WebSockTestIssuer)

      bad_token =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_req_header("authorization", "Bearer bad")

      assert not WebSock.authorized?(bad_token, token_issuer: VoiceConverse.Transport.WebSockTestIssuer)

      assert {:stop, :unauthorized, {4401, "unauthorized"}, _state} =
               Socket.init(WebSock.socket_state([], false))
    end

    test "accepts a bearer header or browser query token" do
      header =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_req_header("authorization", "Bearer good")

      assert WebSock.authorized?(header, token_issuer: VoiceConverse.Transport.WebSockTestIssuer)

      assert WebSock.authorized?(Plug.Test.conn(:get, "/?token=good"),
               token_issuer: VoiceConverse.Transport.WebSockTestIssuer
             )
    end

    test "binds the standalone listener to loopback by default" do
      {:ok, listener} = WebSock.start_link(token_issuer: VoiceConverse.Transport.WebSockTestIssuer)
      Process.unlink(listener)
      on_exit(fn -> Process.exit(listener, :shutdown) end)

      assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
      assert is_integer(port) and port > 0
    end

    test "direct socket callbacks retain the frame-size guard" do
      state = WebSock.socket_state([], true)

      assert {:push, {:text, json}, ^state} = Socket.handle_in({String.duplicate("a", 400_001), :text}, state)
      assert {:ok, %{"type" => "error", "code" => "frame_too_large"}} = VoiceConverse.Wire.decode(json)
    end

    test "the real upgrade closes an oversized frame before buffering it" do
      {:ok, listener} = WebSock.start_link(token_issuer: VoiceConverse.Transport.WebSockTestIssuer)
      Process.unlink(listener)
      on_exit(fn -> Process.exit(listener, :shutdown) end)

      {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      on_exit(fn -> :gen_tcp.close(socket) end)

      :ok = :gen_tcp.send(socket, websocket_upgrade_request())
      assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
      assert response =~ "101 Switching Protocols"

      :ok = :gen_tcp.send(socket, oversized_frame_header(WebSock.max_frame_bytes() + 1))
      assert {:ok, close_frame} = :gen_tcp.recv(socket, 0, 1_000)
      assert close_frame =~ <<0x88, 2, 3, 241>>
    end

    test "only a socket confirm dispatches the client-originated confirmation", %{root: root, name: name} do
      conversation_id = start_session!(root, name)
      draft_id = propose_instruction(name, conversation_id)
      provider = provider_ref(name, conversation_id)

      :ok = FakeProvider.emit(provider, %Events.ToolCall{call_id: "provider", name: "confirm_draft", params: %{}})
      refute_receive {:fake_channel, {:instruct, _, _}}

      state = WebSock.socket_state(instance: name) |> Map.put(:conversation_id, conversation_id)

      assert {:ok, ^state} =
               Socket.handle_in({~s({"v":1,"type":"confirm_draft","draft_id":"#{draft_id}"}), :text}, state)

      assert_receive {:fake_channel, {:instruct, "ship it", ^draft_id}}
    end

    test "a socket discard applies the client-originated terminal state", %{root: root, name: name} do
      conversation_id = start_session!(root, name)
      draft_id = propose_instruction(name, conversation_id)
      state = WebSock.socket_state(instance: name) |> Map.put(:conversation_id, conversation_id)

      assert {:ok, ^state} =
               Socket.handle_in({~s({"v":1,"type":"discard_draft","draft_id":"#{draft_id}"}), :text}, state)

      {:ok, session} = SessionRegistry.lookup(name, conversation_id)
      assert {:ok, %{status: :discarded}} = session |> :sys.get_state() |> Map.fetch!(:drafts) |> Drafts.fetch(draft_id)
      refute_receive {:fake_channel, {:instruct, _, _}}
    end

    test "socket termination starts transport-loss grace for its conversation", %{root: root, name: name} do
      conversation_id = start_session!(root, name)
      {:ok, session} = SessionRegistry.lookup(name, conversation_id)
      session_ref = Process.monitor(session)
      state = WebSock.socket_state(instance: name) |> Map.put(:conversation_id, conversation_id)

      assert :ok = Socket.terminate(:remote, state)
      assert %{subscribers: subscribers, transport_token: token} = :sys.get_state(session)
      assert subscribers == %{}
      assert is_reference(token)

      send(session, {:transport_grace, token})
      assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 1_000
      assert {:ok, records, _meta} = TranscriptStore.read(root, conversation_id)
      assert Enum.any?(records, &(&1["type"] == "session_ended" and &1["reason"] == "transport_lost"))
    end

    test "forwards normalized session events through the wire codec" do
      state = WebSock.socket_state([], true) |> Map.put(:conversation_id, "conversation-1")

      assert {:push, {:text, json}, ^state} =
               Socket.handle_info(
                 {:voice_conversation, "conversation-1",
                  %Events.AgentText{turn_id: "turn-1", text: "hello", final?: true}},
                 state
               )

      assert {:ok, %{"type" => "agent_text", "turn_id" => "turn-1", "text" => "hello", "final" => true}} =
               VoiceConverse.Wire.decode(json)
    end

    defp start_session!(root, name) do
      {:ok, config} =
        Config.new(
          name: name,
          transcript_root: root,
          credentials: StaticCredentials,
          briefing_source: FakeBriefingSource,
          agent_channel: FakeAgentChannel,
          provider: {FakeProvider, []},
          llm: "test-model",
          cloud_disclosure_accepted: true
        )

      start_supervised!(VoiceConverse.child_spec(config))

      assert {:ok, conversation_id} =
               VoiceConverse.start_session(name, %{id: "target", test_pid: self()},
                 client: self(),
                 provider: {FakeProvider, [script: [%Events.ProviderConversationId{id: "provider-session"}]]}
               )

      assert_receive {:voice_conversation_state, ^conversation_id, :connecting}
      assert_receive {:voice_conversation_state, ^conversation_id, :listening}
      conversation_id
    end

    defp propose_instruction(name, conversation_id) do
      :ok =
        FakeProvider.emit(
          provider_ref(name, conversation_id),
          %Events.ToolCall{call_id: "propose", name: "propose_instruction", params: %{"text" => "ship it"}}
        )

      assert_receive {:voice_conversation, ^conversation_id, {:draft, %{draft_id: draft_id, status: "proposed"}}}
      draft_id
    end

    defp provider_ref(name, conversation_id) do
      {:ok, session} = SessionRegistry.lookup(name, conversation_id)
      :sys.get_state(session).provider_ref
    end

    defp websocket_upgrade_request do
      [
        "GET / HTTP/1.1\r\n",
        "Host: 127.0.0.1\r\n",
        "Connection: Upgrade\r\n",
        "Upgrade: websocket\r\n",
        "Authorization: Bearer good\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      ]
    end

    defp oversized_frame_header(size), do: <<0x81, 0xFF, size::unsigned-big-64, 0, 0, 0, 0>>
  end
end
