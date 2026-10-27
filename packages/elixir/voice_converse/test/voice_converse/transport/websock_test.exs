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

    alias VoiceConverse.{Config, Drafts, Events, SessionRegistry}
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

    test "an over-cap frame is rejected without ending the socket session" do
      state = WebSock.socket_state([], true)

      assert {:push, {:text, json}, ^state} = Socket.handle_in({String.duplicate("a", 400_001), :text}, state)
      assert {:ok, %{"type" => "error", "code" => "frame_too_large"}} = VoiceConverse.Wire.decode(json)
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
  end
end
