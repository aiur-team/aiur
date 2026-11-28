defmodule AiurWeb.UsageAccountingApiController do
  @moduledoc "Authenticated per-user provider usage accounting read API."
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Usage.AccountingView

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"user_id" => user_id}) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> json(AccountingView.build(user_id, Application.get_env(:aiur, :usage_accounting_opts, [])))
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET")
    |> put_status(:method_not_allowed)
    |> json(%{error: "method_not_allowed"})
  end
end
