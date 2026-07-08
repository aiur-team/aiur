contaminating_env_vars = [
  "TMUX",
  "TMUX_PANE",
  "ERL_AFLAGS",
  "AIUR_DASHBOARD_USERNAME",
  "AIUR_DASHBOARD_PASSWORD",
  "AIUR_NODE",
  "AIUR_ERLANG_COOKIE",
  "AIUR_TMUX_CONF",
  "AIUR_TMUX_SESSION",
  "AIUR_TMUX_SOCKET",
  "XDG_RUNTIME_DIR",
  "AIUR_LOGS_ROOT"
]

for var <- contaminating_env_vars do
  System.delete_env(var)
end

original_home = System.get_env("HOME")

test_home =
  Path.join(System.tmp_dir!(), "aiur-test-home-#{System.unique_integer([:positive, :monotonic])}")

File.mkdir_p!(test_home)
System.put_env("HOME", test_home)

workflow_file =
  Path.expand("../../.aiurconfig", __DIR__)

test_workflow_fallback = Path.expand("fixtures/test.aiurconfig", __DIR__)

cond do
  File.exists?(workflow_file) ->
    Application.put_env(:aiur, :workflow_file_path, workflow_file)

  File.exists?(test_workflow_fallback) ->
    # CI (and any clone without a per-machine `.aiurconfig`) needs a
    # checked-in fallback so `Aiur.Config.settings!/0` can resolve.
    Application.put_env(:aiur, :workflow_file_path, test_workflow_fallback)

  true ->
    :ok
end

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

ExUnit.start(exclude: [:perf_regression] ++ real_proc_exclude)

ExUnit.after_suite(fn _result ->
  case original_home do
    nil -> System.delete_env("HOME")
    value -> System.put_env("HOME", value)
  end

  File.rm_rf(test_home)

  # Best-effort: IdGenerator's terminate/2 flush at VM shutdown may
  # recreate the counter file after this — a small leftover under the
  # system tmp dir is harmless and tolerated.
  File.rm_rf(Path.dirname(global_log_file))
end)

Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
