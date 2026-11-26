defmodule AiurWeb.Api.UsageProgressController do
  @moduledoc """
  `GET /api/v1/:issue_identifier/progress` — a ticket's current phase, latest
  progress reading and ordered progress events (#5694). Read-only; behind the
  same dashboard Basic auth as `/api/v1/state`.
  """

  use Phoenix.Controller, formats: [:json]

  alias AiurWeb.Api.UsageProgress
  alias AiurWeb.Api.UsageProgress.History
  alias AiurWeb.EndpointConfig
  alias Plug.Conn

  @max_limit History.max_limit()

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"issue_identifier" => identifier}) do
    conn = Conn.fetch_query_params(conn)

    with {:ok, limit} <- parse_limit(Map.get(conn.query_params, "limit")),
         {:ok, payload} <- UsageProgress.payload(identifier, [limit: limit] ++ seams()) do
      conn
      |> Conn.put_resp_header("cache-control", "no-store")
      |> json(payload)
    else
      {:error, :invalid_limit} ->
        error_response(conn, 422, "invalid_limit", "limit must be an integer from 1 to #{@max_limit}")

      {:error, :invalid_identifier} ->
        error_response(conn, 422, "invalid_identifier", "Issue identifier is invalid")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> Conn.put_resp_header("allow", "GET")
    |> error_response(405, "method_not_allowed", "Method not allowed")
  end

  defp parse_limit(nil), do: {:ok, History.default_limit()}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..@max_limit//1 -> {:ok, limit}
      _invalid -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(_value), do: {:error, :invalid_limit}

  # Per-test read-model stubs; unset in production, so the defaults apply.
  defp seams do
    [
      activity_fun: EndpointConfig.get(:usage_progress_activity_fun),
      retention_fun: EndpointConfig.get(:usage_progress_retention_fun),
      history_fun: EndpointConfig.get(:usage_progress_history_fun)
    ]
    |> Enum.reject(fn {_key, fun} -> is_nil(fun) end)
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
