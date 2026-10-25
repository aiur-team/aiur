defmodule AiurWeb.TicketCancelApiController do
  @moduledoc "Authenticated API cancellation with confirmed process-exit evidence."

  use Phoenix.Controller, formats: [:json]

  alias Aiur.Orchestrator
  alias AiurWeb.EndpointConfig
  alias Plug.Conn

  @non_exit_statuses ["still_running", "kill_failed", "generation_changed"]

  @spec cancel(Conn.t(), map()) :: Conn.t()
  def cancel(conn, %{"issue_identifier" => identifier}) do
    case Orchestrator.cancel_agent(orchestrator(), identifier) do
      {:ok, %{process: %{status: "exited"}} = result} ->
        json(conn, result)

      {:ok, %{process: %{status: status}} = result} when status in @non_exit_statuses ->
        conn
        |> put_status(409)
        |> json(result)

      {:error, :no_running_agent} ->
        error_response(conn, 409, "agent_not_running", "Agent is not currently running")

      {:error, :ambiguous_identifier} ->
        error_response(conn, 409, "ambiguous_identifier", "Issue identifier matches more than one running agent")

      {:error, :invalid_identifier} ->
        error_response(conn, 422, "invalid_identifier", "Issue identifier is invalid")

      {:error, reason} when reason in [:timeout, :unavailable] ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

      {:error, {:tracker_cancel_failed, _reason}} ->
        error_response(conn, 503, "cancel_failed", "Cancellation could not update the ticket")

      _other ->
        error_response(conn, 503, "cancel_failed", "Cancellation could not be confirmed")
    end
  end

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
