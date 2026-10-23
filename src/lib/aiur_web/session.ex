defmodule AiurWeb.Session do
  @moduledoc false
  @behaviour Plug

  @impl Plug
  def init(opts), do: Plug.Session.init(opts)

  @impl Plug
  def call(conn, config) do
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])
    configured_secure? = Keyword.get(endpoint_config, :session_options, [])[:secure] == true
    secure? = configured_secure? or conn.scheme == :https
    config = Map.update!(config, :cookie_opts, &Keyword.put(&1, :secure, secure?))
    Plug.Session.call(conn, config)
  end
end
