defmodule Aiur.Opencode.BridgeTest do
  use Aiur.TestSupport, async: false
  import Plug.Conn
  import Plug.Test

  alias Aiur.Opencode.Bridge

  @opts Bridge.init([])

  test "health endpoint is unauthenticated" do
    conn = conn(:get, "/v1/health") |> Bridge.call(@opts)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"ok" => true}
  end

  test "chat completions requires a bearer token for the parsed issue" do
    conn =
      :post
      |> conn(
        "/v1/chat/completions",
        Jason.encode!(%{
          model: "aiur/issue-MT-1",
          messages: [%{role: "user", content: "hello"}],
          stream: true
        })
      )
      |> put_req_header("content-type", "application/json")
      |> Bridge.call(@opts)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"] == "auth_failed"
  end

  test "chat completions rejects invalid model names before auth" do
    conn =
      :post
      |> conn(
        "/v1/chat/completions",
        Jason.encode!(%{
          model: "openai/gpt-4",
          messages: [%{role: "user", content: "hello"}],
          stream: true
        })
      )
      |> put_req_header("content-type", "application/json")
      |> Bridge.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] =~ "invalid_model"
  end
end
