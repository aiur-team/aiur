defmodule AiurWeb.OperatorNotifyApiController do
  @moduledoc "`POST /api/v1/operator/notify`: the daemon API behind `aiur notify`."

  use Phoenix.Controller, formats: [:json]

  alias Aiur.OperatorNotify

  plug(AiurWeb.ProjectScope, :required when action == :create)

  @messages %{
    unknown_kind: "kind must be one of: review_ready, live, stalled, info",
    blank_text: "text must not be blank",
    invalid_ticket: "ticket must be a ticket number or identifier",
    invalid_url: "url must be an absolute http or https URL"
  }

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"kind" => kind, "text" => text} = params) when is_binary(kind) and is_binary(text) do
    case OperatorNotify.notify(kind, text, ticket: params["ticket"], url: params["url"]) do
      {:ok, id} -> conn |> put_status(202) |> json(%{id: id, topic: "operator.notify." <> kind})
      {:error, {:publish_failed, _reason}} -> error_response(conn, 503, "publish_failed", "the event bus did not accept the notification")
      {:error, reason} -> error_response(conn, 422, Atom.to_string(reason), @messages[reason])
    end
  end

  def create(conn, _params), do: error_response(conn, 422, "missing_fields", "kind and text are required strings")

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
