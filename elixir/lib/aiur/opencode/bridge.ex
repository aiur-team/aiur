defmodule Aiur.Opencode.Bridge do
  @moduledoc false

  use Plug.Router

  alias Aiur.Opencode.ChatCompletions

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/v1/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{ok: true}))
  end

  post "/v1/chat/completions" do
    ChatCompletions.handle(conn.body_params, conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
