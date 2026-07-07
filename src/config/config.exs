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
  # Library code must never register real pids/panes into the reaper during
  # unit tests — a draining sweep would kill live host processes. Reaper
  # tests force-enable this against their own dedicated instances.
  config :aiur, :process_reaper_registrations, false

  # Tests manage GITHUB_TOKEN themselves; a boot resolution would cache a nil
  # (no valid token in CI) and shadow the per-test env tokens.
  config :aiur, :resolve_github_token_on_boot, false

  # Suite-global :log_file isolation. The :aiur app boots BEFORE
  # test/test_helper.exs runs (mix test starts apps first), and
  # Aiur.Events.IdGenerator persists <log_root>/<repo>.event_id during
  # init — so this is the only hook early enough to keep boot-time and
  # non-TestSupport test writes out of the shared <cwd>/log. Per-test
  # overrides (Aiur.TestSupport, subscription_store_test) still win;
  # test_helper.exs verifies this value and removes the directory in
  # after_suite.
  test_log_root =
    Path.join(
      System.tmp_dir!(),
      "aiur-test-logs-#{System.os_time(:millisecond)}-#{System.pid()}"
    )

  config :aiur, :log_file, Path.join(test_log_root, "aiur.log")

  config :aiur, :server_host_override, "127.0.0.1"
  config :aiur, :server_port_override, 0
  config :aiur, :opencode_bridge_host_override, "127.0.0.1"
  config :aiur, :opencode_bridge_port_override, 0

  workflow_file_path_for_tests =
    [
      "../../.aiur/config",
      "../../.aiurconfig",
      "../test/fixtures/test.aiurconfig"
    ]
    |> Enum.map(&Path.expand(&1, __DIR__))
    |> Enum.find(&File.exists?/1)

  if workflow_file_path_for_tests do
    config :aiur, :workflow_file_path, workflow_file_path_for_tests
  end
end
