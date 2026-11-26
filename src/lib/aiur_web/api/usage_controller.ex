defmodule AiurWeb.Api.UsageController do
  @moduledoc "Authenticated, read-only per-ticket model usage (`GET /api/v1/:issue_identifier/usage`)."
  use Phoenix.Controller, formats: [:json]

  alias AiurWeb.Api.Usage.TicketUsage
  alias AiurWeb.EndpointConfig

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"issue_identifier" => issue_identifier}) do
    case TicketUsage.fetch(issue_identifier, EndpointConfig.get(:ticket_usage_opts) || []) do
      {:ok, payload} ->
        conn
        |> Plug.Conn.put_resp_header("cache-control", "no-store")
        |> json(payload)

      {:error, :invalid_identifier} ->
        error_response(conn, 422, "invalid_identifier", "Issue identifier must be a GitHub issue number")

      {:error, :usage_not_found} ->
        error_response(conn, 404, "usage_not_found", "No usage recorded for issue")

      {:error, :usage_unresolvable} ->
        error_response(conn, 404, "usage_unresolvable", "No retained usage records for issue; older records may have been compacted")

      {:error, :usage_unavailable} ->
        error_response(conn, 503, "usage_unavailable", "Usage ledger is unavailable")
    end
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET")
    |> error_response(405, "method_not_allowed", "Method not allowed")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
