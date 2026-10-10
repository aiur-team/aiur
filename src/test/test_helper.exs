contaminating_env_vars = [
  "TMUX",
  "TMUX_PANE",
  "ERL_AFLAGS",
  "AIUR_DASHBOARD_USERNAME",
  "AIUR_DASHBOARD_PASSWORD",
  "AIUR_DEBUG",
  "AIUR_SUPERVISOR_TOKEN",
  "AIUR_NODE",
  "AIUR_ERLANG_COOKIE",
  "AIUR_TMUX_CONF",
  "AIUR_TMUX_SESSION",
  "AIUR_TMUX_SOCKET",
  "AIUR_LOGS_ROOT"
]

for var <- contaminating_env_vars do
  System.delete_env(var)
end

# Dashboard routes fail closed when credentials are absent. Keep the broad
# integration-test fixture authenticated by default; tests that exercise the
# missing-configuration path delete these variables explicitly.
System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
System.put_env("AIUR_DASHBOARD_PASSWORD", "test-dashboard-secret")

Code.require_file("support/test_boot_guard.exs", __DIR__)
Aiur.TestBootGuard.check!()

# The suite-global :log_file isolation root is set in config/config.exs
# (test block) so it is in force before the app boots. Fail loudly if it
# is ever missing — without it, boot-time and non-TestSupport writes leak
# into the shared <cwd>/log and unique_integer id reuse across VM boots
# resurrects stale subscription state (ghost auto-resume flakes).
global_log_file = Application.get_env(:aiur, :log_file)

unless is_binary(global_log_file) and
         String.starts_with?(global_log_file, System.tmp_dir!()) do
  raise "config/config.exs must isolate :log_file under the system tmp dir " <>
          "for the test env; got: #{inspect(global_log_file)}"
end

File.mkdir_p!(Path.dirname(global_log_file))

# `:real_proc` tests spawn live processes and read the real /proc filesystem;
# they only run where /proc exists (Linux CI / the dogfood box), and are
# excluded elsewhere (e.g. macOS dev) rather than silently passing.
real_proc_exclude = if File.dir?("/proc"), do: [], else: [:real_proc]

# `:external` tests call a third-party API over the network with a real
# credential. They are evidence gathered on demand — a measurement or a contract
# check against the live provider — never a gate, because a gate that needs the
# internet and someone's API key fails for reasons that have nothing to do with
# the change under test. Run one with `mix test --only external`.
ExUnit.start(exclude: [:external, :perf_regression, :quarantine] ++ real_proc_exclude)

Code.require_file("support/test_tmp.exs", __DIR__)

test_run_root =
  Aiur.TestTmp.start!(Path.join(System.tmp_dir!(), "aiur-elixir-tests-#{System.get_env("USER") || System.get_env("LOGNAME") || "local"}"))

Application.put_env(:aiur, :test_run_root, test_run_root)

ExUnit.after_suite(fn _result ->
  # Best-effort: IdGenerator's terminate/2 flush at VM shutdown may
  # recreate the counter file after this — a small leftover under the
  # system tmp dir is harmless and tolerated.
  File.rm_rf(Path.dirname(global_log_file))
end)

Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/test_cleanup.ex", __DIR__)
Code.require_file("support/agent_control_cli_todo.ex", __DIR__)
Code.require_file("support/live_view_async.ex", __DIR__)
Code.require_file("support/event_ticket.ex", __DIR__)
Code.require_file("support/wake_inbox_ack.ex", __DIR__)
Code.require_file("support/dashboard_font_assertions.ex", __DIR__)
Code.require_file("support/muse_fixture.exs", __DIR__)
Code.require_file("support/decision_dispatch_test_support.ex", __DIR__)
Code.require_file("support/claude_meter_test_support.exs", __DIR__)
Code.require_file("support/build_order_github_graph_test_adapter.ex", __DIR__)
Code.require_file("support/history_backfill_fixture.ex", __DIR__)
Code.require_file("support/browser_harness/fixtures.ex", __DIR__)
Code.require_file("support/usage_ledger_support.ex", __DIR__)
Code.require_file("support/usage_aggregate_support.ex", __DIR__)
Code.require_file("support/allowed_contributors_fixture.ex", __DIR__)
Code.require_file("support/fake_usage_adapter.ex", __DIR__)
Code.require_file("support/grouped_scopes_support.ex", __DIR__)
Code.require_file("support/awaiting_commands_support.ex", __DIR__)
Code.require_file("support/snapshot_fence_support.ex", __DIR__)
Code.require_file("support/tracker_task_drain_support.ex", __DIR__)
Code.require_file("support/webhook_mode_contract.exs", __DIR__)

Code.require_file("support/build_home/fixture_source.ex", __DIR__)
Code.require_file("support/build_home/protocol_case.ex", __DIR__)
Code.require_file("support/webhook_deliveries.ex", __DIR__)
Code.require_file("support/comments_poller_fixture.ex", __DIR__)
Code.require_file("support/webhook_equivalence_fixture.ex", __DIR__)
Code.require_file("support/webhook_poll_fixture.ex", __DIR__)
Code.require_file("support/mutation_fixture.ex", __DIR__)
Code.require_file("support/deposit_fixture.ex", __DIR__)
