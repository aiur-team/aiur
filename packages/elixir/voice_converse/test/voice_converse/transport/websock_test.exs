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
    use ExUnit.Case, async: true

    alias VoiceConverse.Events
    alias VoiceConverse.Transport.WebSock
    alias VoiceConverse.Transport.WebSock.Socket

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

    test "a socket confirm dispatches only the client-originated confirmation" do
      parent = self()

      state =
        WebSock.socket_state(
          [
            api: %{
              confirm_draft: fn conversation_id, draft_id, edited_text ->
                send(parent, {:confirm, conversation_id, draft_id, edited_text})
                :ok
              end
            }
          ],
          true
        )
        |> Map.put(:conversation_id, "conversation-1")

      assert {:ok, ^state} =
               Socket.handle_in({~s({"v":1,"type":"confirm_draft","draft_id":"draft-1"}), :text}, state)

      assert_receive {:confirm, "conversation-1", "draft-1", nil}

      assert {:ok, ^state} =
               Socket.handle_info(
                 {:voice_conversation, "conversation-1",
                  %Events.ToolCall{call_id: "c", name: "confirm_draft", params: %{}}},
                 state
               )

      refute_receive {:confirm, _, _, _}
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
  end
end
