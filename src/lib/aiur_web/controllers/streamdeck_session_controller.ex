defmodule AiurWeb.StreamdeckSessionController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias AiurWeb.StreamdeckAuth

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    case StreamdeckAuth.issue_token() do
      {:ok, token} -> json(conn, %{token: token, expires_in_seconds: StreamdeckAuth.token_max_age_seconds()})
      {:error, :authentication_required} -> conn |> put_status(401) |> json(%{error: %{code: "authentication_required"}})
    end
  end
end
