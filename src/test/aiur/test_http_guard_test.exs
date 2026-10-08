defmodule Aiur.TestHTTPGuardTest do
  use Aiur.TestSupport

  defmodule LocalPlug do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "local response")
  end

  test "default HTTP transport rejects public hosts before connecting" do
    for host <- ["api.linear.app", "example.com", "localhost.example.com", "192.0.2.1"] do
      assert {:error, %RuntimeError{message: message}} =
               Req.get("https://#{host}/", retry: false, connect_options: [timeout: 1])

      assert message ==
               "test HTTP request blocked for #{host}; inject a fake :plug/:adapter or explicitly opt in with adapter: Req.Finch"
    end
  end

  test "default Linear fixture refuses a real poll" do
    assert {:error, {:linear_api_request, %RuntimeError{message: message}}} =
             Aiur.Linear.Client.fetch_candidate_issues()

    assert message =~ "test HTTP request blocked for api.linear.app"
  end

  test "future regression: loopback HTTP still reaches the local server" do
    server = start_supervised!({Bandit, plug: LocalPlug, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert {:ok, %{status: 200, body: "local response"}} = Req.get("http://127.0.0.1:#{port}/")
  end

  test "future regression: Linear adapter tests can explicitly inject a fake HTTP layer" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"data" => %{"issues" => []}}) end)

    assert {:ok, %{status: 200, body: %{"data" => %{"issues" => []}}}} =
             Req.post("https://api.linear.app/graphql", json: %{query: "query { issues { id } }"}, plug: {Req.Test, __MODULE__})
  end
end
