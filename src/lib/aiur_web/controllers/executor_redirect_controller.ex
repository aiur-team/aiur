defmodule AiurWeb.ExecutorRedirectController do
  @moduledoc "The retired `/executor` page: open the Executor footer, or the recorded position in full history."
  use Phoenix.Controller, formats: []
  alias Aiur.Conversation.Ref
  alias Plug.Conn

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"pos" => _} = params) do
    query = URI.encode_query(Map.take(params, ["pos", "placement", "event", "kind"]))
    redirect(conn, to: "/conversations/#{URI.encode(Ref.conversation_id(Ref.executor()), &URI.char_unreserved?/1)}?#{query}")
  end

  def show(conn, _params), do: redirect(conn, to: "/?executor=open")
end
