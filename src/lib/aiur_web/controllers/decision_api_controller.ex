defmodule AiurWeb.DecisionApiController do
  @moduledoc """
  Authenticated machine JSON surface for canonical Decision operations.

  Authentication and mutation safety are router concerns. This controller
  keeps path identity authoritative, injects only trusted runtime options, and
  maps domain outcomes to a small redacted HTTP vocabulary.
  """

  use Phoenix.Controller, formats: [:json]

  alias Aiur.DecisionApi
  alias AiurWeb.Endpoint
  alias Plug.Conn

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    conn
    |> invoke(:list, [params, api_opts(conn)])
    |> render_read(conn)
  end

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"decision_id" => decision_id}) do
    conn
    |> invoke(:get, [decision_id, api_opts(conn)])
    |> render_read(conn)
  end

  @spec enrich(Conn.t(), map()) :: Conn.t()
  def enrich(conn, %{"decision_id" => decision_id} = params) do
    mutation(conn, :enrich, decision_id, params)
  end

  @spec decide(Conn.t(), map()) :: Conn.t()
  def decide(conn, %{"decision_id" => decision_id} = params) do
    mutation(conn, :decide, decision_id, params)
  end

  @spec revise(Conn.t(), map()) :: Conn.t()
  def revise(conn, %{"decision_id" => decision_id} = params) do
    mutation(conn, :revise, decision_id, params)
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp mutation(conn, operation, decision_id, params) do
    payload = Map.delete(params, "decision_id")

    conn
    |> invoke(operation, [decision_id, payload, api_opts(conn)])
    |> render_mutation(conn)
  end

  defp invoke(conn, operation, args) do
    apply(decision_api(conn), operation, args)
  rescue
    _error -> {:error, :store_unavailable}
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  defp render_read({:ok, payload}, conn), do: json(conn, payload)
  defp render_read({:error, reason}, conn), do: render_error(conn, reason)

  defp render_mutation({:ok, payload}, conn) do
    status = Map.get(payload, "status", Map.get(payload, :status))

    if status in ["accepted", "recorded", :accepted, :recorded] do
      conn
      |> put_status(202)
      |> json(payload)
    else
      json(conn, payload)
    end
  end

  defp render_mutation({:error, reason}, conn), do: render_error(conn, reason)

  defp render_error(conn, :not_found) do
    error_response(conn, 404, "decision_not_found", "Decision not found")
  end

  defp render_error(conn, {:indeterminate, %{status: :partial}}) do
    conn
    |> put_status(503)
    |> json(%{
      error: %{
        code: "decision_presence_indeterminate",
        message: "Decision presence cannot be determined from partial retained data"
      },
      scope: %{"kind" => "retained", "label" => "All retained decisions"},
      health: %{
        "status" => "partial",
        "partial" => true,
        "reason" => "retained_store_partial",
        "label" => "Partial retained Decision data"
      }
    })
  end

  defp render_error(conn, {:delegation_forbidden, _details}) do
    error_response(conn, 403, "supervisor_forbidden", "Supervisor action is not authorized")
  end

  defp render_error(conn, {:conflict, _details}) do
    error_response(conn, 409, "decision_conflict", "Decision state changed; refresh and retry")
  end

  defp render_error(conn, :answer_missing) do
    error_response(conn, 409, "decision_conflict", "Decision state changed; refresh and retry")
  end

  defp render_error(conn, {:answer_invalid, {:supervisor_basis, :decision_mismatch}}) do
    error_response(conn, 409, "decision_conflict", "Decision state changed; refresh and retry")
  end

  defp render_error(conn, {:revision_invalid, {:answer_invalid, {:supervisor_basis, :decision_mismatch}}}) do
    error_response(conn, 409, "decision_conflict", "Decision state changed; refresh and retry")
  end

  defp render_error(conn, reason)
       when is_tuple(reason) and
              elem(reason, 0) in [
                :answer_invalid,
                :decision_invalid,
                :delegation_invalid,
                :enrichment_invalid,
                :invalid_decision_id,
                :invalid_enrichment,
                :invalid_list,
                :revision_invalid
              ] do
    error_response(conn, 422, "invalid_request", "Decision request is invalid")
  end

  defp render_error(conn, :store_unavailable) do
    service_unavailable(conn)
  end

  defp render_error(conn, {:store_unavailable, _details}) do
    service_unavailable(conn)
  end

  defp render_error(conn, _reason) do
    service_unavailable(conn)
  end

  defp service_unavailable(conn) do
    error_response(conn, 503, "decision_service_unavailable", "Decision service is unavailable")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp decision_api(conn) do
    conn.private[:decision_api] || endpoint_config(:decision_api) || DecisionApi
  end

  defp api_opts(conn) do
    conn.private
    |> Map.get(:decision_api_opts, [])
    |> maybe_put_new(:actor, conn.assigns[:decision_actor])
    |> maybe_put_endpoint(:store, :decision_store)
    |> maybe_put_endpoint(:policy, :decision_policy)
  end

  defp maybe_put_new(opts, _key, nil), do: opts
  defp maybe_put_new(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp maybe_put_endpoint(opts, option, endpoint_key) do
    maybe_put_new(opts, option, endpoint_config(endpoint_key))
  end

  defp endpoint_config(key) do
    Endpoint.config(key)
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end
end
