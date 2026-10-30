defmodule AiurWeb.UnitsRedirectController do
  @moduledoc false
  use Phoenix.Controller, formats: []
  alias Plug.Conn

  @spec legacy(Conn.t(), map()) :: Conn.t()
  def legacy(conn, _params) do
    destination = if conn.query_string == "", do: "/", else: "/?" <> conn.query_string
    conn |> put_status(:moved_permanently) |> redirect(to: destination)
  end
end
