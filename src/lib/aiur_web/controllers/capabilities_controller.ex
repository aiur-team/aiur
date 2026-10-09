defmodule AiurWeb.CapabilitiesController do
  @moduledoc "Authenticated, read-only capability discovery."
  use Phoenix.Controller, formats: [:json]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> json(Aiur.Capabilities.report([]) |> Aiur.Capabilities.to_wire())
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET")
    |> put_status(:method_not_allowed)
    |> json(%{error: "method_not_allowed"})
  end
end
