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
  alias Aiur.Commands.Scope
  alias AiurWeb.BuildOrderHostApi
  alias AiurWeb.CommandsScopeAuth

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    opts = [contract: "build-order.v1", source: source(conn)] ++ root_opts(params)

    case BuildOrdersCLI.build(opts) do
      {:ok, document} -> respond(conn, 200, document)
      {:error, reason} -> failure(conn, reason)
    end
  end

  @doc "Returns the feature or epic document authorized by the embedded-host grant."
  @spec embedded(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def embedded(conn, _params) do
    case conn.assigns[:command_scope] do
      %{build_order: %{kind: kind, key: key}} = scope when kind in [:feature, :epic] ->
        case BuildOrderHostApi.read(scope, host_opts(conn, key, kind)) do
          {:ok, document} -> respond(conn, 200, document)
          {:error, :not_found} -> error(conn, 404, :build_order_not_found, "Build Order scope was not found")
          {:error, :unavailable} -> error(conn, 503, :build_order_unavailable, "Build Order projection is unavailable")
        end

      _missing_scope ->
        error(conn, 404, :build_order_not_found, "Build Order scope was not found")
    end
  end

  @doc "Mints a short-lived Build Order grant for one feature or epic."
  @spec mint_scope(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mint_scope(conn, %{"principal" => principal, "build_order" => %{"kind" => kind, "key" => key}} = params)
      when is_binary(principal) and kind in ["feature", "epic"] and is_binary(key) do
    with {:ok, secret} <- CommandsScopeAuth.signing_secret(conn),
         {:ok, expires_in} <- build_order_expiry(params),
         {:ok, minted} <- Scope.mint(principal, [], secret: secret, expires_in: expires_in, build_order: %{kind: kind, key: key}) do
      conn
      |> put_status(201)
      |> json(%{"token" => minted.token, "expires_at" => DateTime.to_iso8601(minted.scope.expires_at), "scope" => Scope.to_public(minted.scope)})
    else
      _invalid -> error(conn, 422, :invalid_scope, "Build Order scope request is invalid")
    end
  end

  def mint_scope(conn, _params), do: error(conn, 422, :invalid_scope, "Build Order scope request is invalid")

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

  defp host_opts(conn, key, kind) do
    opts = conn.private[:build_order_host_opts] || []
    opts = Keyword.put(opts, :activity_fun, Keyword.get(opts, :activity_fun, &Aiur.TicketActivity.snapshots/0))

    opts
    |> Keyword.put_new(:scope_kind, kind)
    |> Keyword.put(:scope_key, key)
  end

  defp build_order_expiry(params) do
    case Map.get(params, "expires_in", 900) do
      value when is_integer(value) and value > 0 and value <= 86_400 -> {:ok, value}
      _invalid -> {:error, :invalid_scope}
    end
  end

  defp root_opts(%{"root" => root}) when is_binary(root) and root != "", do: [root: root]
  defp root_opts(_params), do: []

  # `BuildOrdersCLI.build/1` promises a binary message: the projection seam
  # translates the source's typed atom (`BuildOrdersCLI.published/1`), so a type
  # test here would be dead code and this endpoint can match on the text alone.
  defp failure(conn, reason) do
    cond do
      reason =~ "could not find" -> error(conn, 404, :build_order_not_found, reason)
      reason =~ "ambiguous" -> error(conn, 409, :build_order_ambiguous, reason)
      reason =~ "expected --contract" -> error(conn, 422, :invalid_request, reason)
      true -> error(conn, 503, :build_order_unavailable, reason)
    end
  end

  defp error(conn, status, code, message),
    do: respond(conn, status, %{error: %{code: code, message: message}})

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(body)
  end
end
