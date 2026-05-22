import Config

config :aiur, env: config_env()

config :phoenix, :json_library, Jason

config :aiur, AiurWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: AiurWeb.ErrorHTML, json: AiurWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Aiur.PubSub,
  live_view: [signing_salt: "aiur-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

if config_env() == :test do
  config :aiur, :server_host_override, "127.0.0.1"
  config :aiur, :server_port_override, 0
  config :aiur, :opencode_bridge_host_override, "127.0.0.1"
  config :aiur, :opencode_bridge_port_override, 0
end
