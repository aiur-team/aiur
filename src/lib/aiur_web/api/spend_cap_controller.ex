defmodule AiurWeb.Api.SpendCapController do
  @moduledoc "Authenticated per-ticket spend-cap reads and writes."
  use Phoenix.Controller, formats: [:json]

  alias AiurWeb.Api.Usage.TicketSpendCap
  alias AiurWeb.EndpointConfig

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"issue_identifier" => identifier}) do
    respond(conn, TicketSpendCap.fetch(identifier, opts()))
  end

  @spec put(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put(conn, %{"issue_identifier" => identifier} = params) do
    respond(conn, TicketSpendCap.put(identifier, Map.delete(params, "issue_identifier"), opts()))
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"issue_identifier" => identifier}) do
    case TicketSpendCap.delete(identifier, opts()) do
      :ok -> Plug.Conn.send_resp(conn, 204, "")
      {:error, reason} -> error(conn, reason)
    end
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET, PUT, DELETE")
    |> error_response(405, "method_not_allowed", "Method not allowed")
  end

  defp opts, do: EndpointConfig.get(:ticket_spend_cap_opts) || []

  defp respond(conn, {:ok, payload}) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> json(payload)
  end

  defp respond(conn, {:error, reason}), do: error(conn, reason)

  defp error(conn, :invalid_identifier), do: error_response(conn, 422, "invalid_identifier", "Issue identifier must be a GitHub issue number")
  defp error(conn, :invalid_amount), do: error_response(conn, 422, "invalid_amount", "Amount must be a positive decimal string with at most 6 fractional digits")
  defp error(conn, :unsupported_currency), do: error_response(conn, 422, "unsupported_currency", "Only USD spend caps are supported")
  defp error(conn, :ticket_not_found), do: error_response(conn, 404, "ticket_not_found", "Ticket not found in the configured repository")
  defp error(conn, :ticket_unresolvable), do: error_response(conn, 422, "ticket_unresolvable", "Ticket has no repository-qualified tracker identity")
  defp error(conn, :spend_cap_not_found), do: error_response(conn, 404, "spend_cap_not_found", "Ticket has no spend cap")
  defp error(conn, :spend_cap_exhausted), do: error_response(conn, 409, "spend_cap_exhausted", "An exhausted cap cannot be changed")
  defp error(conn, :exhaustion_transition_pending), do: error_response(conn, 409, "exhaustion_transition_pending", "The budget-exhausted ticket transition is still pending")
  defp error(conn, _reason), do: error_response(conn, 503, "spend_cap_unavailable", "Ticket spend caps are unavailable")

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
