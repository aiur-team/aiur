defmodule AiurWeb.ChatRedirectController do
  @moduledoc false
  use Phoenix.Controller, formats: []

  alias Aiur.Bounded
  alias Aiur.GitHub.Config
  alias Plug.Conn

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"owner" => owner, "repository" => repository, "identifier" => identifier}) do
    with {:ok, {owner, repository}} <- Bounded.github_repository_components(owner, repository),
         {:ok, ticket} <- Bounded.github_issue_identifier(identifier),
         true <- byte_size(ticket) <= 10 do
      redirect_repository(conn, %{owner: owner, repository: repository}, ticket)
    else
      _invalid -> unavailable(conn, 404)
    end
  end

  defp redirect_repository(conn, candidate, ticket) do
    reader = conn.private[:aiur_configured_repo] || (&Config.configured_repo/0)

    case reader.() do
      {:ok, {owner, repository}} ->
        if Bounded.same_repository?(candidate, %{owner: owner, repository: repository}),
          do: redirect(conn, to: "/?ticket=" <> ticket),
          else: unavailable(conn, 404)

      {:error, _reason} ->
        unavailable(conn, 503)
    end
  end

  defp unavailable(conn, status) do
    detail = if status == 503, do: " The configured repository cannot be read.", else: ""

    conn
    |> Conn.put_resp_content_type("text/html")
    |> Conn.send_resp(status, ~s(<p>Chat is unavailable for this ticket.#{detail}</p><a href="/">Back to Build</a>))
  end
end
