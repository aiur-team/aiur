defmodule AiurWeb.DashboardCors do
  @moduledoc """
  Cross-origin read access for the gateway summary route only.

  Answers an exact-match `Origin` listed in `server.dashboard_origins`; any other origin gets no CORS
  headers (the browser then fails the request). Never `*`: responses are credentialed.
  """

  @behaviour Plug

  import Plug.Conn

  alias Aiur.Config.DashboardOrigin

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = put_resp_header(conn, "vary", "Origin")

    conn =
      case get_req_header(conn, "origin") do
        [origin] -> if listed_origin?(origin), do: allow(conn, origin), else: conn
        _ -> conn
      end

    if conn.method == "OPTIONS", do: conn |> send_resp(204, "") |> halt(), else: conn
  end

  defp allow(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header("access-control-allow-methods", "GET")
    |> put_resp_header("access-control-allow-headers", "content-type, x-aiur-request-id, authorization")
    |> put_resp_header("access-control-max-age", "600")
  end

  @spec listed_origin?(String.t()) :: boolean()
  def listed_origin?(origin) do
    # Compare the raw header to its normal form: `https://a.ts.net/` is not a browser Origin.
    DashboardOrigin.normalize_origin(origin) == {:ok, origin} and origin in listed_origins()
  end

  @spec listed_origins() :: [String.t()]
  def listed_origins, do: List.wrap(AiurWeb.EndpointConfig.get(:dashboard_origins, []))
end
