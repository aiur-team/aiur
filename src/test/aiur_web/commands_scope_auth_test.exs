defmodule AiurWeb.CommandsScopeAuthTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Aiur.Commands.Scope
  alias AiurWeb.CommandsScopeAuth

  @secret String.duplicate("s", 64)

  test "a valid grant assigns only the verified scope" do
    {:ok, %{token: token}} = Scope.mint("player-7", ["42"], secret: @secret, expires_in: 300)

    conn =
      conn_with_token(token, @secret)
      |> CommandsScopeAuth.call([])

    refute conn.halted
    assert conn.assigns.command_scope.subject == "player-7"
    assert conn.assigns.command_scope.tickets == ["42"]
    assert MapSet.member?(conn.assigns.command_scope.ticket_set, "42")
  end

  test "a missing bearer token is a 401 and halts" do
    conn = CommandsScopeAuth.call(conn_with_token(nil, @secret), [])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "commands_scope_required"
    refute Map.has_key?(conn.assigns, :command_scope)
  end

  test "a token signed with another secret is rejected" do
    {:ok, %{token: token}} = Scope.mint("player-7", ["42"], secret: String.duplicate("x", 64), expires_in: 300)

    conn = CommandsScopeAuth.call(conn_with_token(token, @secret), [])

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "commands_scope_invalid"
  end

  test "an expired grant reports expiry, not a generic failure" do
    now = DateTime.add(DateTime.utc_now(), -10, :second)
    {:ok, %{token: token}} = Scope.mint("player-7", ["42"], secret: @secret, now: now, expires_in: 5)

    conn = CommandsScopeAuth.call(conn_with_token(token, @secret), [])

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "commands_scope_expired"
  end

  test "an instance without a usable signing secret refuses to authenticate" do
    {:ok, %{token: token}} = Scope.mint("player-7", ["42"], secret: @secret, expires_in: 300)

    conn =
      conn_with_token(token, @secret)
      |> Map.put(:private, %{command_scope_secret: "too-short"})
      |> CommandsScopeAuth.call([])

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "commands_scope_unconfigured"
  end

  defp conn_with_token(token, secret) do
    conn = conn(:get, "/api/v1/commands") |> Map.put(:private, %{command_scope_secret: secret})

    case token do
      nil -> conn
      token -> put_req_header(conn, "authorization", "Bearer #{token}")
    end
  end
end
