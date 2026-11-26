defmodule AiurWeb.GatewayHelloController do
  @moduledoc "Anonymous gateway hello: five public identity keys, answered with no credential."
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Gateway.Hello

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    if AiurWeb.EndpointConfig.get(:gateway_hello, false) do
      conn |> Plug.Conn.put_resp_header("cache-control", "no-store") |> json(Hello.body())
    else
      AiurWeb.ObservabilityApiController.not_found(conn, params)
    end
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET")
    |> put_status(:method_not_allowed)
    |> json(%{error: "method_not_allowed"})
  end
end
