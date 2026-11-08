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
    cond do
      Keyword.get(opts, :bearer_only?, false) ->
        conn |> send_resp(401, "unauthorized") |> halt()

      public_bind?() and is_binary(header) and String.starts_with?(String.downcase(header), "basic ") ->
        conn |> send_resp(401, "basic authentication is unavailable on a public bind") |> halt()

      true ->
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

  defp assign_token(conn, t) do
    conn |> assign(:token_name, t.name) |> assign(:token_scope, t.scope) |> assign(:token_peer, t.peer) |> assign(:token_categories, t.categories)
  end

  # REST write routes carry no category of their own: only a token holding every category
  # (legacy write) passes, except the messages route, which maps to `message`.
  # The control endpoint checks the category per call in ControlController.
  defp rest_write_allowed?(%Plug.Conn{path_info: ["api", "v1", "control"]}, _cats), do: true
  defp rest_write_allowed?(%Plug.Conn{path_info: ["api", "v1", _, "messages"]}, cats), do: "message" in cats or full?(cats)
  defp rest_write_allowed?(_conn, cats), do: full?(cats)

  defp full?(cats), do: Enum.all?(Aiur.ClientTokens.categories(), &(&1 in cats))

  defp authenticate(conn, token, write?) when is_binary(token) do
    case Aiur.ClientTokens.authenticate_full(token) do
      {:ok, %{scope: "write"} = t} ->
        if rest_write_allowed?(conn, t.categories) do
          assign_token(conn, t)
        else
          conn |> send_resp(403, "forbidden") |> halt()
        end

      {:ok, t} when not write? ->
        assign_token(conn, t)

      {:ok, _} ->
        conn |> send_resp(403, "forbidden") |> halt()

      :error ->
        conn |> send_resp(401, "unauthorized") |> halt()
    end
  end
end
