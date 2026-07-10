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
  end
end
