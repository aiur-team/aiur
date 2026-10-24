Code.require_file("support/test_environment.ex", __DIR__)
Aiur.TestEnvironment.clear_inherited!()

# Container probes must never observe the host's real cgroup from tests unless
# a test explicitly installs its own fake cgroup tree.
test_cgroup_root = Path.join(System.tmp_dir!(), "aiur-test-cgroup-disabled-#{System.unique_integer([:positive])}")
if File.exists?(test_cgroup_root), do: raise("test cgroup root must not exist: #{test_cgroup_root}")
Application.put_env(:aiur, :cgroup_root_override, test_cgroup_root)

run_orchestrator_guard_probes = System.get_env("AIUR_RUN_ORCHESTRATOR_GUARD_PROBES") == "1"

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

workspace_root = Path.expand("../..", __DIR__)

manual_sandbox_reset_exclude =
  if System.get_env("AIUR_AGENT_WORKSPACE") || String.contains?(workspace_root, "/aiur-workspaces/"),
    do: [:manual_sandbox_reset],
    else: []

# `:external` tests call a third-party API over the network with a real
# credential. They are evidence gathered on demand — a measurement or a contract
# check against the live provider — never a gate, because a gate that needs the
# internet and someone's API key fails for reasons that have nothing to do with
# the change under test. Run one with `mix test --only external`.
quarantine_path = Path.join(__DIR__, "quarantine.txt")

quarantine_entries =
  case Aiur.TestQuarantine.read(quarantine_path) do
    {:ok, entries} -> entries
    {:error, reason} -> raise "invalid test quarantine list #{quarantine_path}: #{inspect(reason)}"
  end

quarantine_filters =
  if System.get_env("AIUR_RUN_QUARANTINED") == "1",
    do: [],
    else: Aiur.TestQuarantine.filters(quarantine_entries)

ExUnit.start(
  formatters:
    if(System.get_env("AIUR_TEST_PROGRESS") == "1",
      do: [ExUnit.CLIFormatter, Aiur.TestSupport.ProgressFormatter],
      else: [ExUnit.CLIFormatter]
    ),
  exclude:
    [:external, :perf_regression, :quarantine] ++
      if(run_orchestrator_guard_probes, do: [], else: [:orchestrator_guard_probe]) ++
      real_proc_exclude ++
      manual_sandbox_reset_exclude ++ quarantine_filters
)

Code.require_file("support/test_tmp.exs", __DIR__)

dashboard_secret_root = Application.fetch_env!(:aiur, :dashboard_secret_root)

Aiur.TestTmp.after_final_round(fn _result ->
  Application.delete_env(:aiur, :dashboard_secret_root)
  Aiur.TestCleanup.rm_rf!(dashboard_secret_root)
end)

test_run_root =
  Aiur.TestTmp.start!(Path.join(System.tmp_dir!(), "aiur-elixir-tests-#{System.get_env("USER") || System.get_env("LOGNAME") || "local"}"))

Application.put_env(:aiur, :test_run_root, test_run_root)
# Teardown reaps ticket containers; tests must never reach the host's Docker daemon.
Application.put_env(:aiur, :docker_cleanup_command, fn "docker", _args, _opts -> {"", 0} end)

# The run root's late writers (#4866): `Aiur.RunTelemetry.Writer` and
# `Aiur.SaturationSentinel` read `:log_file` once at init, so one restarted
# inside a workflow case keeps appending to that case's `<workflow_root>/log`
# after teardown, until the VM exits. Stop the app before the root is removed;
# `after_suite` callbacks run last-registered first.
Aiur.TestTmp.after_final_round(fn _result -> Application.stop(:aiur) end)

suite_runtime_state_dir = Application.fetch_env!(:aiur, :runtime_state_dir)

unless Path.dirname(Aiur.AlertLedger.path()) == suite_runtime_state_dir do
  raise "alert ledger must use the suite runtime state root #{suite_runtime_state_dir}"
end

Aiur.TestTmp.after_final_round(fn _result ->
  # Best-effort: IdGenerator's terminate/2 flush at VM shutdown may
  # recreate the counter file after this — a small leftover under the
  # system tmp dir is harmless and tolerated.
  File.rm_rf(Path.dirname(global_log_file))
end)

Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support/workflow_yaml_sections.exs", __DIR__)
Code.require_file("support/test_support/workflow_yaml.exs", __DIR__)
Code.require_file("support/test_support/orchestrator_child.exs", __DIR__)
Code.require_file("support/test_support/runtime_children.exs", __DIR__)
Code.require_file("support/test_support/orchestrator_guard.exs", __DIR__)
Code.require_file("support/test_cleanup.ex", __DIR__)
Code.require_file("support/test_support/runner_tasks.exs", __DIR__)
ExUnit.configure(formatters: ExUnit.configuration()[:formatters] ++ [Aiur.TestSupport.OrchestratorGuard])
ExUnit.after_suite(fn _result -> Aiur.TestSupport.RunnerTasks.verify_suite!() end)
ExUnit.after_suite(fn _result -> Aiur.TestSupport.OrchestratorGuard.verify_suite!() end)

Code.require_file("support/test_support/endpoint_stubs.exs", __DIR__)
Code.require_file("support/test_support/processes.exs", __DIR__)
Code.require_file("support/test_support/workflow_files.exs", __DIR__)
Code.require_file("support/test_cleanup.ex", __DIR__)
Code.require_file("support/test_scope_guard.exs", __DIR__)
Code.require_file("support/test_support/lifecycle_leak_guard.ex", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/test_reset_support.ex", __DIR__)
Code.require_file("support/orchestrator_status_support.ex", __DIR__)
Code.require_file("support/agent_control_cli_todo.ex", __DIR__)
Code.require_file("support/turn_loop_test_support.ex", __DIR__)
Code.require_file("support/account_generation_test_support.ex", __DIR__)
Code.require_file("support/ci_lifecycle_test_support.ex", __DIR__)
Code.require_file("support/auto_resume_test_support.ex", __DIR__)
Code.require_file("support/global_pause_test_support.ex", __DIR__)
Code.require_file("support/live_view_async.ex", __DIR__)
Code.require_file("support/refresh_trace.ex", __DIR__)
Code.require_file("support/github_client_test_support.ex", __DIR__)
Code.require_file("support/event_ticket.ex", __DIR__)

# These imports must load before the glob, which sorts cache support before its dependency.
Code.require_file("support/agent_github_guard_test_support.ex", __DIR__)
Code.require_file("support/agent_github_guard_cache_support.ex", __DIR__)
Code.require_file("support/agent_github_guard_case.ex", __DIR__)

# Support loads by glob, so a new support file needs no line here.
Code.put_compiler_option(:no_warn_undefined, :all)

for file <- Enum.sort(Path.wildcard(Path.join(__DIR__, "support/**/*.{ex,exs}"))) do
  Code.require_file(file)
end

Code.put_compiler_option(:no_warn_undefined, [])

Aiur.TestSupport.EndpointStubs.init!()
Aiur.TestSupport.LifecycleLeakGuard.start!()
Aiur.TestSupport.LifecycleLeakGuard.install_late_log_handler!()

# Keep plain ExUnit.Case modules and between-case application timers from
# publishing Orchestrator poll state or alerts into the suite-wide ledger.
Aiur.TestSupport.quiesce_live_orchestrator()
