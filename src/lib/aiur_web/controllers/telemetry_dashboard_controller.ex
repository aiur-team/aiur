defmodule AiurWeb.TelemetryDashboardController do
  @moduledoc """
  Authenticated, read-only browser surface for the current run telemetry.

  The input path is always `Aiur.RunTelemetry.telemetry_file/0`; request
  parameters can neither select nor traverse the filesystem. Rendering reuses
  the same reducer and self-contained HTML document as the CLI generator.
  """

  use Phoenix.Controller, formats: [:html]

  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Dashboard
  alias Plug.Conn

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, _params) do
    case Dashboard.render_inputs(RunTelemetry.telemetry_file()) do
      {:ok, %{html: html}} ->
        conn
        |> no_store()
        |> put_resp_content_type("text/html", "utf-8")
        |> send_resp(200, html)

      {:error, {:no_telemetry_files, _paths}} ->
        unavailable(conn, 404, "Telemetry analytics require a debug telemetry run.")

      {:error, _reason} ->
        unavailable(conn, 503, "Telemetry analytics are temporarily unavailable.")
    end
  end

  defp unavailable(conn, status, message) do
    conn
    |> no_store()
    |> put_resp_content_type("text/plain", "utf-8")
    |> send_resp(status, message)
  end

  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store, max-age=0")
    |> put_resp_header("pragma", "no-cache")
  end
end
