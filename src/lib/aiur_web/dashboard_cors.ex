defmodule AiurWeb.DashboardCors do
  @moduledoc """
  Cross-origin read access for the gateway summary route only.

  Answers an exact-match `Origin` listed in `server.dashboard_origins`; any other origin gets no CORS
  headers (the browser then fails the request). Never `*`: responses are credentialed.
  """

  @behaviour Plug

  import Plug.Conn

  @loopback ["localhost", "127.0.0.1", "[::1]", "::1"]

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
    normalize_origin(origin) == {:ok, origin} and origin in listed_origins()
  end

  @spec listed_origins() :: [String.t()]
  def listed_origins, do: List.wrap(AiurWeb.EndpointConfig.get(:dashboard_origins, []))

  @doc "Normalise to `scheme://host[:port]`; `http` is accepted for loopback hosts only."
  @spec normalize_origin(term()) :: {:ok, String.t()} | :error
  def normalize_origin(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and path in [nil, "", "/"] ->
        render(scheme, String.downcase(host), port)

      _ ->
        :error
    end
  end

  def normalize_origin(_), do: :error

  @doc "Normalised origin, or the entry unchanged when it is not an origin (validation reports it)."
  @spec normalize_or_keep(String.t()) :: String.t()
  def normalize_or_keep(value) do
    case normalize_origin(value) do
      {:ok, origin} -> origin
      :error -> value
    end
  end

  defp render("http", host, _port) when host not in @loopback, do: :error
  defp render("https", host, port), do: {:ok, "https://#{host}" <> port_suffix(port, 443)}
  defp render("http", host, port), do: {:ok, "http://#{host}" <> port_suffix(port, 80)}

  defp port_suffix(port, default) when port in [nil, default], do: ""
  defp port_suffix(port, _default), do: ":#{port}"
end
