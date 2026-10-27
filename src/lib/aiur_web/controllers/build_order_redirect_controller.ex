defmodule AiurWeb.BuildOrderRedirectController do
  @moduledoc false
  use Phoenix.Controller, formats: []

  alias Aiur.Bounded
  alias Aiur.BuildOrder.Features
  alias AiurWeb.Build.URLState
  alias Plug.Conn

  # Old Build Order links land on the Build home. Only the root (as its imported
  # feature) and a `ticket` carry over; both pass through the home URL parser,
  # so user input never reaches Location unvalidated.
  @spec catalog(Conn.t(), map()) :: Conn.t()
  def catalog(conn, _params), do: moved(conn, nil)

  @spec root(Conn.t(), map()) :: Conn.t()
  def root(conn, %{"root_number" => raw}) do
    case Bounded.github_issue_identifier(raw) do
      {:ok, id} -> moved(conn, id |> String.to_integer() |> Features.root_slug())
      :error -> moved(conn, nil)
    end
  end

  defp moved(conn, feature) do
    conn = Conn.fetch_query_params(conn)

    destination =
      case %{"feature" => feature, "ticket" => conn.query_params["ticket"]} |> URLState.parse() |> URLState.to_query() do
        "" -> "/"
        query -> "/?" <> query
      end

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: destination)
  end
end
