defmodule Aiur.Opencode.ChatCompletionsTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Opencode.ChatCompletions
  alias Aiur.Opencode.TokenRegistry
  alias Aiur.Opencode.WorkspaceSetup

  setup do
    token = "test-#{System.unique_integer([:positive])}"
    identifier = "bridge-test-#{System.unique_integer([:positive])}"
    :ok = TokenRegistry.put(token, 1, 1, [identifier])
    on_exit(fn -> TokenRegistry.delete(token) end)
    %{token: token, identifier: identifier}
  end

  test "materialized slot token allows assigned models and rejects foreign tickets before every route" do
    workspace = Aiur.TestSupport.tmp_root!("bridge-token-scope")
    {:ok, token} = WorkspaceSetup.materialize_slot(workspace, "http://127.0.0.1:1", ["ticket-a", "ticket-c"], 97, 1, display_identifier: "ticket-a")

    on_exit(fn ->
      TokenRegistry.delete(token)
      File.rm_rf!(workspace)
    end)

    for model <- ["issue-ticket-a", "aiur/issue-ticket-a", "issue-_slot-97"] do
      body = %{"model" => model, "messages" => [%{"role" => "user", "content" => "__aiur_stream__:nudge:1"}]}
      assert ChatCompletions.handle(body, authorized_conn(token)).status == 200
    end

    assert :ok = TokenRegistry.allow_identifier(token, "ticket-d")
    body = %{"model" => "issue-ticket-d", "messages" => [%{"role" => "user", "content" => "__aiur_stream__:nudge:1"}]}
    assert ChatCompletions.handle(body, authorized_conn(token)).status == 200

    for model <- ["issue-ticket-b", "aiur/issue-ticket-b", "issue-ticket-c", "issue-_slot-98"],
        text <- ["__aiur_stream__:nudge:1", "__aiur_stream__:msg_ABC", "__aiur_turn__:absent", "continue"] do
      body = %{"model" => model, "messages" => [%{"role" => "user", "content" => text}]}
      response = ChatCompletions.handle(body, authorized_conn(token))
      assert response.status == 403

      assert Jason.decode!(response.resp_body) == %{
               "error" => "forbidden",
               "message" => "Bridge token does not authorize the requested ticket identifier."
             }
    end
  end

  defp authorized_conn(token), do: conn(:post, "/") |> put_req_header("authorization", "Bearer #{token}")

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
    test "phantom turn (no ActiveTurns entry) closes with finish_reason stop", %{token: token, identifier: identifier} do
      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => "__aiur_turn__:phantom-abc"}]
      }

      # No ActiveTurns.put → lookup returns :not_found → finalize_stream(:done) → "stop"
      result = ChatCompletions.handle(body, authorized_conn(token))

      assert result.status == 200
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end

    test "late close ({:closed, reason}) renders the reason content then closes with stop", %{token: token, identifier: identifier} do
      turn_id = "late-turn-#{System.unique_integer()}"

      :ok = ActiveTurns.put(identifier, turn_id)
      :ok = ActiveTurns.mark_closed(identifier, turn_id, {:failed, :boom})

      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => "__aiur_turn__:#{turn_id}"}]
      }

      result = ChatCompletions.handle(body, authorized_conn(token))

      assert result.status == 200
      # finalize_stream({:failed, reason}) chunks the inspect(reason) before "stop"
      assert result.resp_body =~ "boom"
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end
  end

  describe "nudge marker" do
    test "nudge marker returns an empty data:[DONE] SSE stream", %{token: token, identifier: identifier} do
      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => "__aiur_stream__:nudge:1"}]
      }

      result = ChatCompletions.handle(body, authorized_conn(token))

      assert result.status == 200
      assert result.resp_body == "data: [DONE]\n\n"
    end
  end

  describe "validate_body/1 taxonomy (via dispatch path)" do
    test "body exceeding 65 536 bytes yields a 400 body-too-large response", %{token: token, identifier: identifier} do
      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => String.duplicate("x", 65_537)}]
      }

      result = ChatCompletions.handle(body, authorized_conn(token))

      assert result.status == 400
      assert Jason.decode!(result.resp_body)["error"] =~ "body too large"
    end

    test "invalid UTF-8 in the last user message yields a 400 invalid-utf8 response", %{token: token, identifier: identifier} do
      body = %{
        "model" => "issue-#{identifier}",
        # <<0xFF, 0xFE>> is not valid UTF-8
        "messages" => [%{"role" => "user", "content" => <<0xFF, 0xFE>>}]
      }

      result = ChatCompletions.handle(body, authorized_conn(token))

      assert result.status == 400
      assert Jason.decode!(result.resp_body)["error"] =~ "invalid_utf8"
    end
  end

  describe "chunk/4 closed-conn tolerance" do
    test "chunk writes on a disconnected conn return the conn unchanged without raising", %{token: token, identifier: identifier} do
      # ClosedConnAdapter delegates send_chunked to the real adapter (so the
      # conn transitions to :chunked state) but returns {:error, :closed} for
      # every chunk write. The phantom-turn path calls send_chunked once then
      # chunk/4 once for the finish chunk; chunk/4 must handle {:error, :closed}
      # gracefully — log once and return the conn unchanged rather than raising.
      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => "__aiur_turn__:phantom-chunk-tol"}]
      }

      base_conn = authorized_conn(token)
      {_, adapter_state} = base_conn.adapter
      stub_conn = %{base_conn | adapter: {ClosedConnAdapter, adapter_state}}

      # Must not raise; chunk/4 handles {:error, :closed} by returning conn
      result = ChatCompletions.handle(body, stub_conn)
      assert %Plug.Conn{} = result
    end
  end
end
