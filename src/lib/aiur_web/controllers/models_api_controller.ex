defmodule AiurWeb.ModelsApiController do
  @moduledoc "Authenticated configured-model priority read API."
  use Phoenix.Controller, formats: [:json]

  alias AiurWeb.FinancialDataAccess
  alias AiurWeb.ModelsProjection
  alias AiurWeb.OperatorControlCenter.ProviderMeterSource

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    meters =
      case FinancialDataAccess.context_from_session(Plug.Conn.get_session(conn)) do
        {:ok, context} -> ProviderMeterSource.load(context)
        :error -> %{}
      end

    snapshot = ModelsProjection.snapshot(meters: meters)
    conn |> Plug.Conn.put_resp_header("cache-control", "no-store") |> json(snapshot)
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn |> Plug.Conn.put_resp_header("allow", "GET") |> put_status(:method_not_allowed) |> json(%{error: "method_not_allowed"})
  end
end
