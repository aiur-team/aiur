defmodule Aiur.PrMerge.ClientTest do
  use ExUnit.Case, async: true

  alias Aiur.PrMerge.Client

  test "operator transport sends uppercase HTTP methods and decodes the response" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_address, port}} = :inet.sockname(listener)

    for {method, expected} <- [{"get", "GET"}, {"post", "POST"}, {"put", "PUT"}] do
      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
          :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}")
          :gen_tcp.close(socket)
          request |> String.split("\r\n") |> hd()
        end)

      transport = fn opts -> Req.request(Keyword.put(opts, :url, "http://127.0.0.1:#{port}/merge")) end
      assert {:ok, %{"ok" => true}} = Client.request("test-credential", method, "merge", nil, transport)
      assert Task.await(server) == "#{expected} /merge HTTP/1.1"
    end
  end
end
