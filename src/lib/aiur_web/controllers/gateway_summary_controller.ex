defmodule AiurWeb.GatewaySummaryController do
  @moduledoc "Read-only gateway summary for the dashboard, readable cross-origin from listed origins."
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Gateway.Summary

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> json(Summary.build())
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET")
    |> put_status(:method_not_allowed)
    |> json(%{error: "method_not_allowed"})
  end
end
