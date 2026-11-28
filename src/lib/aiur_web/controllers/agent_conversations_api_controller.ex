defmodule AiurWeb.AgentConversationsApiController do
  @moduledoc "`POST /api/v1/agent-conversations`: starts an on-demand agent conversation for a host app (#8154)."

  use Phoenix.Controller, formats: [:json]

  alias AiurWeb.AgentConversations

  plug(AiurWeb.ProjectScope, :required when action == :create)

  @messages %{
    blank_text: "text is required",
    text_too_long: "text is longer than 20,000 bytes",
    invalid_owner: "owner must be the host's user id (letters, digits, . _ : @ -)",
    invalid_path: "path must be a relative path inside the repository",
    invalid_skills: "skills must be up to 8 lowercase slugs",
    logs_too_long: "logs are longer than 50,000 bytes",
    invalid_complexity: "complexity must be an integer from 1 to 5",
    invalid_request_id: "client_request_id must be 1-128 letters, digits, . _ : -",
    invalid_images: "images must be up to 8 objects with a GitHub HTTPS URL and optional alt_text (max 400 bytes)",
    repository_unavailable: "the configured GitHub repository could not be resolved"
  }

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case AgentConversations.start(params) do
      {:ok, %{created: true} = started} -> conn |> put_status(201) |> json(started)
      {:ok, started} -> json(conn, started)
      {:error, {:tracker, _reason}} -> error_response(conn, 503, "tracker_unavailable", "the ticket for the conversation could not be filed")
      {:error, {:announcement, _step, _reason}} -> error_response(conn, 503, "announcement_unavailable", "the conversation was filed but its Executor notification or refresh failed")
      {:error, reason} -> error_response(conn, 422, Atom.to_string(reason), @messages[reason])
    end
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> error_response(405, "method_not_allowed", "Method not allowed")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
