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

  workflow_file_path_for_tests =
    [
      "../local-workflows/WORKFLOW.aiur.local.md",
      "../test/fixtures/test_workflow.md"
    ]
    |> Enum.map(&Path.expand(&1, __DIR__))
    |> Enum.find(&File.exists?/1)

  if workflow_file_path_for_tests do
    config :aiur, :workflow_file_path, workflow_file_path_for_tests
  end
end
