defmodule AiurWeb.ObservabilityApiControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.Claude.HookEvents

  # api_write endpoints require a loopback Origin + the X-Aiur-Request header.
  defp hook_conn(identifier, payload) do
    :post
    |> conn("/api/v1/#{identifier}/claude-hook", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("origin", "http://127.0.0.1")
    |> put_req_header("x-aiur-request", "1")
  end

  defp call(conn), do: AiurWeb.Endpoint.call(conn, AiurWeb.Endpoint.init([]))

  describe "POST /api/v1/:id/claude-hook" do
    test "dispatches a Stop event to the agent topic and returns 200" do
      :ok = HookEvents.subscribe("MT-EP")

      conn =
        call(
          hook_conn("MT-EP", %{
            "hook_event_name" => "Stop",
            "last_assistant_message" => "PONG",
            "session_id" => "s1",
            "cwd" => "/w"
          })
        )

      assert conn.status == 200
      assert_receive {:claude_hook, "MT-EP", %{event: :stop, message: "PONG"}}, 500
    end

    test "returns 200 even for an unknown/inactive identifier (never errors claude)" do
      conn = call(hook_conn("MT-NOBODY", %{"hook_event_name" => "Stop", "last_assistant_message" => "x"}))
      assert conn.status == 200
    end

    test "rejects without the X-Aiur-Request header" do
      conn =
        :post
        |> conn("/api/v1/MT-EP/claude-hook", Jason.encode!(%{"hook_event_name" => "Stop"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "http://127.0.0.1")
        |> call()

      assert conn.status == 403
    end
  end
end
