defmodule AiurWeb.CommandsRedirectController do
  @moduledoc false

  use Phoenix.Controller, formats: []

  alias Plug.Conn

  @spec legacy(Conn.t(), map()) :: Conn.t()
  def legacy(conn, _params) do
    destination = conn.request_path |> String.replace_prefix("/decisions", "/commands") |> append_query(conn.query_string)

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: destination)
  end

  defp append_query(path, ""), do: path
  defp append_query(path, query), do: path <> "?" <> query
end
