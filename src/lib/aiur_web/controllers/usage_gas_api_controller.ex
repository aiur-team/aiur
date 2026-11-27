defmodule AiurWeb.UsageGasApiController do
  @moduledoc "Authenticated paid API spend recording endpoint."
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Usage.GasLedger

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case params["user_id"] do
      user_id when is_binary(user_id) ->
        if String.trim(user_id) == "" do
          invalid_user_id(conn)
        else
          record(conn, params)
        end

      _missing_or_invalid ->
        invalid_user_id(conn)
    end
  end

  defp invalid_user_id(conn), do: conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_user_id"}})

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
