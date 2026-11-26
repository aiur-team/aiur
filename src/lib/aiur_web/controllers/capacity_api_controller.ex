defmodule AiurWeb.CapacityApiController do
  @moduledoc "Authenticated, read-only `aiur.capacity` v1 view (#7893); the same payload as `aiur capacity --json`."
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Capacity.View

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> json(View.build())
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET")
    |> put_status(:method_not_allowed)
    |> json(%{error: "method_not_allowed"})
  end
end
