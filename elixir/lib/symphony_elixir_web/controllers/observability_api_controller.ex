defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec send_message(Conn.t(), map()) :: Conn.t()
  def send_message(conn, %{"issue_identifier" => issue_identifier} = params) do
    text = Map.get(params, "text") || Map.get(params, "message") || ""

    issue_identifier
    |> send_operator_message(text)
    |> render_send_message_response(conn, issue_identifier)
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp send_operator_message(issue_identifier, text) do
    Orchestrator.send_operator_message(orchestrator(), issue_identifier, %{kind: :text, body: text})
  end

  defp render_send_message_response({:ok, request_id}, conn, issue_identifier) do
    conn
    |> put_status(202)
    |> json(%{request_id: request_id, issue_identifier: issue_identifier})
  end

  defp render_send_message_response({:error, :no_running_agent}, conn, _issue_identifier) do
    error_response(conn, 409, "agent_not_running", "Agent is not currently running")
  end

  defp render_send_message_response({:error, :empty_message}, conn, _issue_identifier) do
    error_response(conn, 422, "empty_message", "Message is empty")
  end

  defp render_send_message_response({:error, :message_too_long}, conn, _issue_identifier) do
    error_response(conn, 422, "message_too_long", "Message is too long")
  end

  defp render_send_message_response({:error, reason}, conn, _issue_identifier) do
    error_response(conn, 503, "send_failed", inspect(reason))
  end
end
