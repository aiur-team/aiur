defmodule AiurWeb.Session do
  @moduledoc false
  @behaviour Plug

  alias Aiur.Config.SessionOptions

  @impl Plug
  def init(opts), do: Plug.Session.init(opts)

  @impl Plug
  def call(conn, config) do
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])
    configured_secure? = Keyword.get(endpoint_config, :session_options, [])[:secure] == true
    secure? = configured_secure? or conn.scheme == :https

    config =
      Map.update!(config, :cookie_opts, fn cookie_opts ->
        cookie_opts
        |> Keyword.put(:secure, secure?)
        |> Keyword.put(:max_age, SessionOptions.runtime_options()[:max_age])
      end)

    Plug.Session.call(conn, config)
  end
end
