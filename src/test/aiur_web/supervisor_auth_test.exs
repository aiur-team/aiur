defmodule AiurWeb.SupervisorAuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AiurWeb.SupervisorAuth

  @token String.duplicate("a", 32)
  @rotated_token String.duplicate("b", 32)
  @actor %{kind: :supervisor, id: "supervising-agent"}

  setup do
    original_token = System.get_env("AIUR_SUPERVISOR_TOKEN")

    on_exit(fn -> restore_env("AIUR_SUPERVISOR_TOKEN", original_token) end)

    :ok
  end

  test "authenticates one valid bearer token and injects the trusted actor" do
    System.put_env("AIUR_SUPERVISOR_TOKEN", @token)

    conn = authenticate("Bearer #{@token}")

    refute conn.halted
    assert conn.assigns.decision_actor == @actor
  end

  test "the authenticated actor cannot be replaced by request content" do
    System.put_env("AIUR_SUPERVISOR_TOKEN", @token)

    conn =
      :post
      |> conn("/api/v1/decisions/example/decide", %{
        "actor" => %{"kind" => "human", "id" => "operator"}
      })
      |> put_req_header("authorization", "Bearer #{@token}")
      |> SupervisorAuth.call(SupervisorAuth.init([]))

    assert conn.assigns.decision_actor == @actor
  end

  test "missing or invalid configured credentials fail closed" do
    invalid_tokens = [nil, "", "   ", String.duplicate("a", 31), " " <> @token, @token <> " ", String.duplicate(":", 32)]

    for token <- invalid_tokens do
      restore_env("AIUR_SUPERVISOR_TOKEN", token)

      conn = authenticate("Bearer #{@token}")

      assert_unauthorized(conn)
    end
  end

  test "missing, malformed, duplicate, and mismatched authorization headers share one response" do
    System.put_env("AIUR_SUPERVISOR_TOKEN", @token)

    invalid_headers = [
      nil,
      "",
      @token,
      "Basic #{@token}",
      "Bearer",
      "Bearer wrong",
      "Bearer #{@token} trailing"
    ]

    for header <- invalid_headers do
      header |> authenticate() |> assert_unauthorized()
    end

    duplicate =
      conn(:get, "/api/v1/decisions")
      |> Map.put(:req_headers, [
        {"authorization", "Bearer #{@token}"},
        {"authorization", "Bearer #{@token}"}
      ])
      |> SupervisorAuth.call(SupervisorAuth.init([]))

    assert_unauthorized(duplicate)
  end

  test "reads the configured token on every request so rotation is immediate" do
    System.put_env("AIUR_SUPERVISOR_TOKEN", @token)
    refute authenticate("Bearer #{@token}").halted

    System.put_env("AIUR_SUPERVISOR_TOKEN", @rotated_token)

    authenticate("Bearer #{@token}") |> assert_unauthorized()
    refute authenticate("bearer #{@rotated_token}").halted
  end

  test "auth failures never echo either credential" do
    System.put_env("AIUR_SUPERVISOR_TOKEN", @token)

    conn = authenticate("Bearer #{@rotated_token}")
    body = conn.resp_body

    assert_unauthorized(conn)
    refute body =~ @token
    refute body =~ @rotated_token
  end

  defp authenticate(nil) do
    conn(:get, "/api/v1/decisions")
    |> SupervisorAuth.call(SupervisorAuth.init([]))
  end

  defp authenticate(header) do
    :get
    |> conn("/api/v1/decisions")
    |> put_req_header("authorization", header)
    |> SupervisorAuth.call(SupervisorAuth.init([]))
  end

  defp assert_unauthorized(conn) do
    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Bearer realm=\"Aiur Supervisor\""]

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => "supervisor_auth_required",
               "message" => "Supervisor authentication required"
             }
           }
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
