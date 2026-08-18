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

# Demo / pre-ticket planning mode: render a Build Order in the spatial dashboard
# straight from a local planning pack (no GitHub issues). Enable at build time
# with AIUR_BUILD_ORDER_DEMO=1. Remove this block + priv/build_orders to delete.
if System.get_env("AIUR_BUILD_ORDER_DEMO") in ~w(1 true) do
  config :aiur, :build_order_data_source, AiurWeb.BuildOrder.PlanningSource
end

if config_env() == :test do
  # Library code must never register real pids/panes into the reaper during
  # unit tests — a draining sweep would kill live host processes. Reaper
  # tests force-enable this against their own dedicated instances.
  config :aiur, :process_reaper_registrations, false

  # Tests manage GITHUB_TOKEN themselves; a boot resolution would cache a nil
  # (no valid token in CI) and shadow the per-test env tokens.
  config :aiur, :resolve_github_token_on_boot, false
  config :aiur, :workspace_github_preflight_enabled, false
  config :aiur, :github_quota_refresh?, false
  config :aiur, :elevenlabs_quota_refresh?, false
  config :aiur, :github_budget_enabled?, false
  config :aiur, :github_quota_status_override, :available

  # No test may reach a provider's model catalogue over the network. Discovery
  # tests drive `Aiur.ModelDiscovery.refresh/2` with an injected fetcher; the
  # lazy background refresh every other test could trip is off entirely.
  config :aiur, :model_discovery_refresh?, false

  # The shared app process exists only as infrastructure for unit tests. Named
  # Orchestrators that exercise polling start themselves with the production
  # default, but this singleton must not poll across sequential test boundaries.
  config :aiur, :orchestrator_initial_poll?, false

  # The shared app's Ad Hoc overlay poller must not reach GitHub across
  # sequential test boundaries; tests that exercise it start their own named
  # instance with an injected request_fun.
  config :aiur, :build_order_adhoc_poll?, false

  # Likewise the pack status projection: it reads GitHub and writes status.json
  # beside every discovered pack, so the shared app must stay idle.
  config :aiur, :build_order_pack_status_poll?, false

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

  # Same isolation rationale as :log_file above: the always-on DecisionStore
  # child (OCC-1) must never resolve into a real Executor's AIUR_BG_STATE_DIR
  # during tests. Per-test overrides (Application.put_env in a test's own
  # setup) still win.
  config :aiur, :decision_state_dir, Path.join(test_log_root, "decisions")
  config :aiur, :workspace_ownership_sync_fun, fn -> :ok end

  config :aiur, :server_host_override, "127.0.0.1"
  config :aiur, :server_port_override, 0
  config :aiur, :opencode_bridge_host_override, "127.0.0.1"
  config :aiur, :opencode_bridge_port_override, 0

  # Suite-global :workflow_file_path baseline isolation. The :aiur app boots
  # BEFORE test/test_helper.exs runs, so this config block is the only hook
  # early enough to keep the baseline out of the checked-out repo. Every path
  # the code derives from Path.dirname(workflow_file_path()) — model-usage.json,
  # model-catalog.json, ci-readiness.json, the alerts dir — lands beside the
  # active workflow config, so a baseline pointing at src/test/fixtures/test.yaml
  # dirties the working tree with durable cross-run state (#2134). Copy the
  # fixture into the same per-VM tmp root as :log_file / :decision_state_dir:
  # the fixture stays readable while every derived path resolves outside the
  # checkout. Per-test overrides (Aiur.TestSupport) still win.
  File.mkdir_p!(test_log_root)
  test_workflow_file_path = Path.join(test_log_root, "test.yaml")
  File.cp!(Path.expand("../test/fixtures/test.yaml", __DIR__), test_workflow_file_path)

  config :aiur, :workflow_file_path, test_workflow_file_path
end
