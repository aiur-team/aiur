defmodule AiurWeb.TicketCancelApiController do
  @moduledoc "Authenticated API cancellation with confirmed process-exit evidence."

  use Phoenix.Controller, formats: [:json]

  alias Aiur.Orchestrator
  alias AiurWeb.EndpointConfig
  alias Plug.Conn

  @non_exit_statuses ["still_running", "kill_failed", "generation_changed"]

  @spec cancel(Conn.t(), map()) :: Conn.t()
  def cancel(conn, %{"issue_identifier" => identifier}) do
    orchestrator()
    |> Orchestrator.cancel_agent(identifier)
    |> cancel_response(conn)
  end

  defp cancel_response({:ok, %{process: %{status: "exited"}} = result}, conn),
    do: json(conn, result)

  defp cancel_response({:ok, %{process: %{status: status}} = result}, conn)
       when status in @non_exit_statuses do
    conn
    |> put_status(409)
    |> json(result)
  end

  defp cancel_response({:error, :no_running_agent}, conn),
    do: error_response(conn, 409, "agent_not_running", "Agent is not currently running")

  defp cancel_response({:error, :issue_not_found}, conn),
    do: error_response(conn, 404, "issue_not_found", "Issue not found")

  defp cancel_response({:error, :ambiguous_identifier}, conn),
    do: error_response(conn, 409, "ambiguous_identifier", "Issue identifier matches more than one running agent")

  defp cancel_response({:error, :invalid_identifier}, conn),
    do: error_response(conn, 422, "invalid_identifier", "Issue identifier is invalid")

  defp cancel_response({:error, reason}, conn) when reason in [:timeout, :unavailable],
    do: error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

  defp cancel_response({:error, {:tracker_cancel_failed, _reason}}, conn),
    do: error_response(conn, 503, "cancel_failed", "Cancellation could not update the ticket")

  defp cancel_response(_other, conn),
    do: error_response(conn, 503, "cancel_failed", "Cancellation could not be confirmed")

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> error_response(405, "method_not_allowed", "Method not allowed")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator, do: EndpointConfig.get(:orchestrator) || Aiur.Orchestrator
end
