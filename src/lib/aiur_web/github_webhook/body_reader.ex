defmodule AiurWeb.GithubWebhook.BodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that caches the raw request body for the GitHub
  webhook receiver.

  `Plug.Parsers` consumes the request body, and a body can only be read once.
  Without this reader the verification plug would have to re-encode the parsed
  map, producing different bytes than GitHub signed and a signature that never
  matches. The raw bytes are stashed in `conn.private` under
  `AiurWeb.GithubWebhook.raw_body_key/0`.

  Caching is scoped to the receiver path so ordinary dashboard requests keep
  their existing memory profile and 8 MB parser limit.
  """

  alias AiurWeb.GithubWebhook

  @doc """
  Reads the request body, caching it verbatim for webhook deliveries.

  Oversized deliveries return `{:more, ...}` so `Plug.Parsers` raises its
  standard request-too-large error rather than verifying a truncated body.
  """
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    if GithubWebhook.receiver_request?(conn) do
      read_and_cache(conn, opts)
    else
      Plug.Conn.read_body(conn, opts)
    end
  end

  defp read_and_cache(conn, opts) do
    opts = Keyword.put(opts, :length, GithubWebhook.max_body_bytes())

    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, Plug.Conn.put_private(conn, GithubWebhook.raw_body_key(), body)}
      other -> other
    end
  end
end
