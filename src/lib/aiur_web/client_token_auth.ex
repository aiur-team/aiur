defmodule AiurWeb.ClientTokenAuth do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    if api_path?(conn) do
      authenticate_header(conn, opts)
    else
      AiurWeb.Router.dashboard_basic_auth(conn, opts)
    end
  end

  defp authenticate_header(conn, opts) do
    case get_req_header(conn, "authorization") do
      [header] when is_binary(header) ->
        case bearer_value(header) do
          nil -> basic_fallback(conn, opts, header)
          token -> authenticate(conn, token, Keyword.get(opts, :write?, false))
        end

      headers when length(headers) > 1 ->
        conn |> send_resp(401, "ambiguous authorization header") |> halt()

      _ ->
        basic_fallback(conn, opts, nil)
    end
  end

  defp basic_fallback(conn, opts, header) do
    if public_bind?() and is_binary(header) and String.starts_with?(String.downcase(header), "basic ") do
      conn |> send_resp(401, "basic authentication is unavailable on a public bind") |> halt()
    else
      opts = if public_bind?(), do: Keyword.put(opts, :required?, true), else: opts
      AiurWeb.Router.dashboard_basic_auth(conn, opts)
    end
  end

  defp public_bind? do
    AiurWeb.EndpointConfig.get(:public_bind, false) == true
  rescue
    _ -> false
  end

  defp api_path?(%Plug.Conn{path_info: ["api", "v1" | _]}), do: true
  defp api_path?(_), do: false

  defp bearer_value(header) do
    case String.split(header, ~r/\s+/, parts: 2, trim: true) do
      [scheme, token] when is_binary(token) -> if(String.downcase(scheme) == "bearer", do: token, else: nil)
      _ -> nil
    end
  end

  defp authenticate(conn, token, write?) when is_binary(token) do
    case Aiur.ClientTokens.authenticate(token) do
      {:ok, name, scope} when not write? or scope == "write" ->
        conn |> assign(:token_name, name) |> assign(:token_scope, scope)

      {:ok, _name, _scope} ->
        conn |> send_resp(403, "forbidden") |> halt()

      :error ->
        conn |> send_resp(401, "unauthorized") |> halt()
    end
  end

  defp authenticate(conn, _, _), do: conn |> send_resp(401, "unauthorized") |> halt()
end
