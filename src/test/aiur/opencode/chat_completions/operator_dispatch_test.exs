defmodule Aiur.Opencode.ChatCompletions.OperatorDispatchTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Aiur.Opencode.ChatCompletions.OperatorDispatch
  alias Aiur.Opencode.TokenRegistry

  describe "dispatch_user_text/4" do
    test "operator text path closes SSE with stop as soon as send_operator accepts" do
      identifier = "ack-#{System.unique_integer()}"
      token = "ack-tok-#{System.unique_integer()}"
      :ok = TokenRegistry.put(token, 1, 1)

      # A pure scaffold reminder (no real operator text) normalizes to ""
      # → send_operator returns {:ok, :noop} → stream_turn closes SSE with "stop"
      # without entering any receive loop (ack-fast contract).
      noop_text = "<system-reminder>cwd changed to /tmp</system-reminder>"

      body = %{"stream" => true}

      test_conn =
        :post
        |> conn("/")
        |> put_req_header("authorization", "Bearer #{token}")

      result = OperatorDispatch.dispatch_user_text(body, test_conn, identifier, noop_text)

      assert result.status == 200
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end

    test "non-stream request returns a chat.completion JSON body" do
      identifier = "ns-#{System.unique_integer()}"
      token = "ns-tok-#{System.unique_integer()}"
      :ok = TokenRegistry.put(token, 1, 1)

      noop_text = "<system-reminder>cwd changed to /tmp</system-reminder>"
      body = %{"stream" => false}

      test_conn =
        :post
        |> conn("/")
        |> put_req_header("authorization", "Bearer #{token}")

      result = OperatorDispatch.dispatch_user_text(body, test_conn, identifier, noop_text)

      assert result.status == 200
      assert result.resp_body =~ ~s("object":"chat.completion")
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end

    test "returns 401 with the auth-failed body when the bearer token is missing" do
      test_conn = conn(:post, "/")

      result = OperatorDispatch.dispatch_user_text(%{}, test_conn, "id-401", "real message")

      assert result.status == 401
      assert result.resp_body =~ "auth_failed"
    end

    test "returns 400 when the request body exceeds the size cap" do
      oversized = String.duplicate("x", 65_537)

      result = OperatorDispatch.dispatch_user_text(%{}, conn(:post, "/"), "id-big", oversized)

      assert result.status == 400
      assert result.resp_body =~ "body too large"
    end

    test "returns 400 for an invalid-UTF8 body" do
      result = OperatorDispatch.dispatch_user_text(%{}, conn(:post, "/"), "id-utf8", <<0xFF, 0xFE>>)

      assert result.status == 400
    end
  end

  describe "send_operator/3" do
    test "noops a scaffolding-only reminder without forwarding to the agent" do
      scaffold = "<system-reminder>opencode file-open scaffolding</system-reminder>"

      assert {:ok, :noop} = OperatorDispatch.send_operator("id-noop", scaffold, "turn-1")
    end
  end
end
