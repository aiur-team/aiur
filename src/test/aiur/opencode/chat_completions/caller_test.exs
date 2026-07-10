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

  describe "writer/2" do
    test "returns nil (segmentation disabled) when the caller's base_url can't be resolved" do
      conn = conn(:post, "/")
      assert Caller.writer(conn, "id-no-writer") == nil
    end

    test "returns nil for an invalid bearer token" do
      conn = conn(:post, "/") |> put_req_header("authorization", "Bearer invalid-token")
      assert Caller.writer(conn, "id-bad-token") == nil
    end
  end
end
