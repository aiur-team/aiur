defmodule AiurWeb.UsageGasApiController do
  @moduledoc "Authenticated paid API spend recording endpoint."
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Usage.GasLedger

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    if params["user_id"] == System.get_env("AIUR_USAGE_USER_ID") do
      record(conn, params)
    else
      conn |> put_status(:not_found) |> json(%{error: %{code: "unknown_user"}})
    end
  end

  defp record(conn, params) do
    server = Application.get_env(:aiur, :usage_gas_ledger_server, GasLedger)

    case GasLedger.record(Map.take(params, ~w(id user_id api amount_usd occurred_at basis ticket conversation_id)), server) do
      {:ok, row} -> conn |> put_status(:created) |> json(%{recorded: true, duplicate: false, record: row})
      {:duplicate, row} -> json(conn, %{recorded: true, duplicate: true, record: row})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: to_string(reason)}})
    end
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn |> Plug.Conn.put_resp_header("allow", "POST") |> put_status(:method_not_allowed) |> json(%{error: "method_not_allowed"})
  end
end
