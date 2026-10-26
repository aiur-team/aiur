defmodule AiurWeb.ControlBodyReader do
  @moduledoc "Applies the control endpoint's smaller parser limit before JSON decoding."

  @max_body_bytes 65_536

  alias AiurWeb.ControlBodyLimit
  alias AiurWeb.GithubWebhook.BodyReader

  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    if conn.path_info == ["api", "v1", "control"] do
      case ControlBodyLimit.cached_body(conn) do
        {:ok, _body, _conn} = cached -> cached
        :missing -> Plug.Conn.read_body(conn, Keyword.put(opts, :length, @max_body_bytes))
      end
    else
      BodyReader.read_body(conn, opts)
    end
  end
end
