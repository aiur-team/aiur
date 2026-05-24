contaminating_env_vars = [
  "TMUX",
  "TMUX_PANE",
  "ERL_AFLAGS",
  "AIUR_NODE",
  "AIUR_ERLANG_COOKIE",
  "AIUR_TMUX_CONF",
  "AIUR_TMUX_SESSION",
  "AIUR_TMUX_SOCKET",
  "XDG_RUNTIME_DIR"
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
  Path.expand("../local-workflows/WORKFLOW.aiur.local.md", __DIR__)

if File.exists?(workflow_file) do
  Application.put_env(:aiur, :workflow_file_path, workflow_file)
end

ExUnit.start(exclude: [:perf_regression])

ExUnit.after_suite(fn _result ->
  case original_home do
    nil -> System.delete_env("HOME")
    value -> System.put_env("HOME", value)
  end

  File.rm_rf(test_home)
end)

Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
