defmodule AiurWeb.PlanningDocumentController do
  @moduledoc false
  use Phoenix.Controller, formats: []
  alias Aiur.BuildOrder.Bounded
  alias AiurWeb.BuildOrder.PlanningSource

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"owner" => owner, "repository" => repository, "root_number" => root, "member_number" => member}) do
    with {:ok, {owner, repository}} <- Bounded.github_repository_components(owner, repository),
         {:ok, root} <- Bounded.github_issue_identifier(root),
         {:ok, member} <- Bounded.github_issue_identifier(member),
         {:ok, body} <- PlanningSource.document(owner, repository, root, member) do
      conn |> put_resp_content_type("text/plain") |> put_resp_header("cache-control", "no-store") |> put_resp_header("x-content-type-options", "nosniff") |> send_resp(200, body)
    else
      _unavailable -> send_resp(conn, 404, "Planning document unavailable")
    end
  end
end
