defmodule Aiur.Opencode.ChatCompletions.CallerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Aiur.Opencode.ChatCompletions.Caller

  describe "authorize/1" do
    test "returns {:error, :unauthorized} when no Bearer header is present" do
      conn = conn(:post, "/")
      assert {:error, :unauthorized} = Caller.authorize(conn)
    end

    test "returns {:error, :unauthorized} when Bearer token is invalid" do
      conn = conn(:post, "/") |> put_req_header("authorization", "Bearer invalid-token")
      assert {:error, :unauthorized} = Caller.authorize(conn)
    end
  end

  describe "base_url/1" do
    test "returns :error when no Bearer header is present" do
      conn = conn(:post, "/")
      assert :error = Caller.base_url(conn)
    end

    test "returns :error when Bearer token is invalid" do
      conn = conn(:post, "/") |> put_req_header("authorization", "Bearer invalid-token")
      assert :error = Caller.base_url(conn)
    end
  end

  describe "auth_failed_body/0" do
    test "returns a map with :error and :message keys" do
      body = Caller.auth_failed_body()
      assert is_map(body)
      assert Map.has_key?(body, :error)
      assert Map.has_key?(body, :message)
    end
  end
end
