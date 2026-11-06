defmodule AiurWeb.BuildOrderApiController do
  @moduledoc """
  The published `build-order.v1` read surface.

  `GET /api/v1/build-order` reads the whole catalog and
  `GET /api/v1/build-order?root=<number>` reads one selected root. Both encode
  the same projection the dashboard renders, so another tool can draw the review
  and graph without re-implementing the join. The document itself comes from
  `Aiur.BuildOrder.Published`; this controller only selects the projection and
  maps a failed read onto the API's typed error envelope.
  """

  use Phoenix.Controller, formats: [:json]

  alias Aiur.BuildOrdersCLI

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    opts = [contract: "build-order.v1", source: source(conn)] ++ root_opts(params)

    case BuildOrdersCLI.build(opts) do
      {:ok, document} -> respond(conn, 200, document)
      {:error, reason} -> failure(conn, reason)
    end
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn |> Plug.Conn.put_resp_header("allow", "GET") |> error(422, :method_not_allowed, "method not allowed")
  end

  # The read surface defaults to the daemon's projection source and accepts an
  # injected one so a test reads a deterministic projection, matching the
  # private-assign seam the other API controllers use.
  defp source(conn) do
    Map.get(conn.private, :build_order_data_source) ||
      Application.get_env(:aiur, :build_order_data_source, AiurWeb.BuildOrder.DataSource)
  end

  defp root_opts(%{"root" => root}) when is_binary(root) and root != "", do: [root: root]
  defp root_opts(_params), do: []

  defp failure(conn, reason) when is_binary(reason) do
    cond do
      reason =~ "could not find" -> error(conn, 404, :build_order_not_found, reason)
      reason =~ "ambiguous" -> error(conn, 409, :build_order_ambiguous, reason)
      reason =~ "expected --contract" -> error(conn, 422, :invalid_request, reason)
      true -> error(conn, 503, :build_order_unavailable, reason)
    end
  end

  defp failure(conn, _reason), do: error(conn, 503, :build_order_unavailable, "could not read the Build Order projection")

  defp error(conn, status, code, message),
    do: respond(conn, status, %{error: %{code: code, message: message}})

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(body)
  end
end
