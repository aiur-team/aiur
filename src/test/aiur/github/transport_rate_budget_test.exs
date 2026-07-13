defmodule Aiur.GitHub.TransportRateBudgetTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{RateBudget, Transport}

  setup do
    :sys.replace_state(RateBudget, fn _ -> nil end)
    :ets.delete(RateBudget, :observation)

    on_exit(fn ->
      :sys.replace_state(RateBudget, fn _ -> nil end)
      :ets.delete(RateBudget, :observation)
    end)

    :ok
  end

  test "GET responses update the REST rate budget" do
    assert {:ok, %{status: 200}} = request_once(:get, "core")
    assert %{remaining: 0} = :sys.get_state(RateBudget)
  end

  test "mutation responses update the REST rate budget without blocking" do
    for method <- [:post, :patch, :delete] do
      :sys.replace_state(RateBudget, fn _ -> nil end)
      :ets.delete(RateBudget, :observation)

      assert {:ok, %{status: 200}} = request_once(method, "core")
      assert %{remaining: 0} = :sys.get_state(RateBudget)
    end
  end

  test "mutation responses do not wait for a suspended rate budget" do
    :sys.suspend(RateBudget)

    try do
      task = Task.async(fn -> request_once(:post, "core") end)
      assert {:ok, {:ok, %{status: 200}}} = Task.yield(task, 500)
    after
      :sys.resume(RateBudget)
    end
  end

  test "GraphQL responses do not update the REST rate budget" do
    assert {:ok, %{status: 200}} = request_once(:post, "graphql")
    assert nil == :sys.get_state(RateBudget)
  end

  defp request_once(method, resource) do
    {url, server} = start_http_server(resource)

    request = %{method: method, url: url, token: "test-token"}
    request = if method in [:post, :patch], do: Map.put(request, :body, %{}), else: request
    result = Transport.default_request_fun(request)
    Task.await(server)
    result
  end

  defp start_http_server(resource) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
        now = System.system_time(:second)

        response =
          "HTTP/1.1 200 OK\r\n" <>
            "content-type: application/json\r\n" <>
            "content-length: 2\r\n" <>
            "connection: close\r\n" <>
            "x-ratelimit-limit: 5000\r\n" <>
            "x-ratelimit-remaining: 0\r\n" <>
            "x-ratelimit-reset: #{now + 1_000}\r\n" <>
            "x-ratelimit-resource: #{resource}\r\n\r\n{}"

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {"http://127.0.0.1:#{port}", server}
  end
end
