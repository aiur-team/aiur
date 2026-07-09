defmodule Aiur.Opencode.ChatCompletionsTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Aiur.Opencode.ChatCompletions
  alias Aiur.Opencode.{ActiveTurns, TokenRegistry}

  # ── Wave 0: conn-path characterization ────────────────────────────────────

  # Stub adapter whose chunk/2 returns {:error, :closed} so the chunk/4
  # closed-conn tolerance test can exercise the graceful-error path without
  # needing a real disconnected socket.
  defmodule ClosedConnAdapter do
    @behaviour Plug.Conn.Adapter

    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
    defdelegate send_file(state, status, headers, path, offset, length), to: Plug.Adapters.Test.Conn
    defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn
    defdelegate get_peer_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_sock_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_ssl_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn
    defdelegate inform(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate upgrade(state, protocol, opts), to: Plug.Adapters.Test.Conn
    defdelegate push(state, path, headers), to: Plug.Adapters.Test.Conn

    def chunk(_state, _body), do: {:error, :closed}
  end

  describe "stream_codex_turn: phantom and late-close conn paths" do
    test "phantom turn (no ActiveTurns entry) closes with finish_reason stop" do
      identifier = "phantom-#{System.unique_integer()}"

      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => "__aiur_turn__:phantom-abc"}]
      }

      # No ActiveTurns.put → lookup returns :not_found → finalize_stream(:done) → "stop"
      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 200
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end

    test "late close ({:closed, reason}) renders the reason content then closes with stop" do
      identifier = "late-#{System.unique_integer()}"
      turn_id = "late-turn-#{System.unique_integer()}"

      :ok = ActiveTurns.put(identifier, turn_id)
      :ok = ActiveTurns.mark_closed(identifier, turn_id, {:failed, :boom})

      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => "__aiur_turn__:#{turn_id}"}]
      }

      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 200
      # finalize_stream({:failed, reason}) chunks the inspect(reason) before "stop"
      assert result.resp_body =~ "boom"
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end
  end

  describe "nudge marker" do
    test "nudge marker returns an empty data:[DONE] SSE stream" do
      body = %{
        "model" => "issue-nudge-#{System.unique_integer()}",
        "messages" => [%{"role" => "user", "content" => "__aiur_stream__:nudge:1"}]
      }

      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 200
      assert result.resp_body == "data: [DONE]\n\n"
    end
  end

  describe "replay: stream marker not-found path" do
    test "stream marker with no session renders **system:** message not found then stop" do
      # No bearer token → resolve_session_for_replay returns nil
      # → nil && Db.fetch_message_with_parts(nil, id) = nil → not-found branch
      body = %{
        "model" => "issue-replay-#{System.unique_integer()}",
        "messages" => [%{"role" => "user", "content" => "__aiur_stream__:msg_ABCDEF"}]
      }

      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 200
      assert result.resp_body =~ "message not found"
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end
  end

  describe "operator dispatch: ack-fast SSE close" do
    test "operator text path closes SSE with stop as soon as send_operator accepts" do
      identifier = "ack-#{System.unique_integer()}"
      token = "ack-tok-#{System.unique_integer()}"
      :ok = TokenRegistry.put(token, 1, 1)

      # A pure scaffold reminder (no real operator text) normalizes to ""
      # → send_operator returns {:ok, :noop} → stream_turn closes SSE with "stop"
      # without entering any receive loop (ack-fast contract).
      noop_text = "<system-reminder>cwd changed to /tmp</system-reminder>"

      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => noop_text}],
        "stream" => true
      }

      test_conn =
        :post
        |> conn("/")
        |> put_req_header("authorization", "Bearer #{token}")

      result = ChatCompletions.handle(body, test_conn)

      assert result.status == 200
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end
  end

  describe "validate_body/1 taxonomy (via dispatch path)" do
    test "body exceeding 65 536 bytes yields a 400 body-too-large response" do
      body = %{
        "model" => "issue-vb-#{System.unique_integer()}",
        "messages" => [%{"role" => "user", "content" => String.duplicate("x", 65_537)}]
      }

      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 400
      assert Jason.decode!(result.resp_body)["error"] =~ "body too large"
    end

    test "invalid UTF-8 in the last user message yields a 400 invalid-utf8 response" do
      body = %{
        "model" => "issue-vb-#{System.unique_integer()}",
        # <<0xFF, 0xFE>> is not valid UTF-8
        "messages" => [%{"role" => "user", "content" => <<0xFF, 0xFE>>}]
      }

      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 400
      assert Jason.decode!(result.resp_body)["error"] =~ "invalid_utf8"
    end
  end

  describe "chunk/4 closed-conn tolerance" do
    test "chunk writes on a disconnected conn return the conn unchanged without raising" do
      # ClosedConnAdapter delegates send_chunked to the real adapter (so the
      # conn transitions to :chunked state) but returns {:error, :closed} for
      # every chunk write. The phantom-turn path calls send_chunked once then
      # chunk/4 once for the finish chunk; chunk/4 must handle {:error, :closed}
      # gracefully — log once and return the conn unchanged rather than raising.
      identifier = "chunk-tol-#{System.unique_integer()}"

      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => "__aiur_turn__:phantom-chunk-tol"}]
      }

      base_conn = conn(:post, "/")
      {_, adapter_state} = base_conn.adapter
      stub_conn = %{base_conn | adapter: {ClosedConnAdapter, adapter_state}}

      # Must not raise; chunk/4 handles {:error, :closed} by returning conn
      result = ChatCompletions.handle(body, stub_conn)
      assert %Plug.Conn{} = result
    end
  end
end
