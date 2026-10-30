defmodule AiurWeb.ExecutorHookController do
  @moduledoc "Acknowledges authenticated hooks before processing any lifecycle work."
  use Phoenix.Controller, formats: [:json]
  alias Aiur.Executor.SessionIngest

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    conn = Plug.Conn.fetch_query_params(conn)
    SessionIngest.dispatch(conn.body_params, conn.query_params["harness"])
    conn |> put_status(202) |> json(%{ok: true})
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params), do: conn |> put_resp_header("allow", "POST") |> put_status(405) |> json(%{error: %{code: "method_not_allowed"}})
end
