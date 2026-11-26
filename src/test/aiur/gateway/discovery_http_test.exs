defmodule Aiur.Gateway.DiscoveryHttpTest do
  use ExUnit.Case, async: true

  alias Aiur.Gateway.Discovery

  defmodule Stub do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/off"} = conn, _), do: send_resp(conn, 404, "")
    def call(%{request_path: "/garbage"} = conn, _), do: send_resp(conn, 200, "<html>")
    def call(%{request_path: "/ok"} = conn, _), do: send_resp(conn, 200, ~s({"gateway_id":"g"}))
    def call(conn, _), do: send_resp(conn, 500, "")
  end

  setup do
    {:ok, pid} = Bandit.start_link(plug: Stub, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{base: "http://127.0.0.1:#{port}"}
  end

  test "http_get keeps a disabled hello (404) apart from a garbage or failing one", %{base: base} do
    assert Discovery.http_get(base <> "/off") == {:error, :hello_disabled}
    assert Discovery.http_get(base <> "/garbage") == {:error, :unrecognised}
    assert Discovery.http_get(base <> "/boom") == {:error, :unrecognised}
    assert Discovery.http_get(base <> "/ok") == {:ok, %{"gateway_id" => "g"}}
  end
end
