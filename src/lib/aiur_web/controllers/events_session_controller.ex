defmodule AiurWeb.EventsSessionController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Aiur.Events.Export
  alias AiurWeb.EventsAuth

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    conn = Plug.Conn.put_resp_header(conn, "cache-control", "no-store")
    if Export.enabled?(), do: issue(conn), else: conn |> put_status(404) |> json(%{error: %{code: "feature_disabled"}})
  end

  defp issue(conn) do
    case EventsAuth.issue_token() do
      {:ok, token} -> json(conn, %{token: token, expires_in_seconds: EventsAuth.token_max_age_seconds()})
      {:error, :authentication_required} -> conn |> put_status(401) |> json(%{error: %{code: "authentication_required"}})
    end
  end
end
