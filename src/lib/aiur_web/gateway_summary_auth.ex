defmodule AiurWeb.GatewaySummaryAuth do
  @moduledoc """
  Auth for the gateway summary: a dashboard session cookie or a bearer client token, nothing else.

  Unlike `ClientTokenAuth` it never sends `WWW-Authenticate`, so a cross-origin 401 cannot open a native
  credential prompt and the page can tell "signed out" from "unreachable".
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: Keyword.take(opts, [:write?])

  @impl Plug
  def call(conn, opts) do
    case get_req_header(conn, "authorization") do
      [] -> session(conn)
      [header] -> bearer(conn, header, Keyword.get(opts, :write?, false))
      _ -> deny(conn, "unauthorized")
    end
  end

  # A read-scoped token can read the summary but must not pause a gateway.
  defp bearer(conn, header, write?) do
    with ["bearer", token] <- header |> String.split(~r/\s+/, parts: 2, trim: true) |> lower_scheme(),
         {:ok, name, scope} when not write? or scope == "write" <- Aiur.ClientTokens.authenticate(token) do
      assign(conn, :token_name, name)
    else
      _ -> deny(conn, "unauthorized")
    end
  end

  defp lower_scheme([scheme, token]), do: [String.downcase(scheme), token]
  defp lower_scheme(other), do: other

  defp session(conn) do
    case AiurWeb.FinancialDataAccess.context_from_session(get_session(conn)) do
      {:ok, _context} -> conn
      :error -> deny(conn, "signed_out")
    end
  end

  defp deny(conn, error) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: error}))
    |> halt()
  end
end
