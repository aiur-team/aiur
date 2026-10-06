defmodule Aiur.Opencode.ChatCompletions.InputIdentityTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.Opencode.ChatCompletions.InputIdentity
  alias Aiur.Opencode.TokenRegistry

  setup do
    token = "input-parts-#{System.unique_integer([:positive])}"
    :ok = TokenRegistry.put(token, 93, 1)

    connection =
      conn(:post, "/v1/chat/completions")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("x-aiur-input-version", "1")

    %{connection: connection}
  end

  test "post-transform text parts survive alongside the original user action", %{connection: connection} do
    envelope = "__aiur_input_v1__:" <> Jason.encode!(%{session: "ses_one", message: "msg_one", text: "question"})

    body = %{
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => envelope},
            %{"type" => "text", "text" => "What did we do so far?"}
          ]
        }
      ]
    }

    assert {:ok, %{"messages" => [message]}} = InputIdentity.unwrap(body, connection)
    assert message["content"] == "questionWhat did we do so far?"
    assert message[:aiur_message_id] == "opencode:ses_one:msg_one"
  end

  test "a compaction prompt inserted after the hook remains unkeyed synthetic content", %{connection: connection} do
    message = %{"role" => "user", "content" => [%{"type" => "text", "text" => "Summarize the preceding conversation."}]}
    body = %{"messages" => [message]}

    assert {:ok, %{"messages" => [decoded]}} = InputIdentity.unwrap(body, connection)
    assert decoded == message
    refute Map.has_key?(decoded, :aiur_message_id)
  end
end
