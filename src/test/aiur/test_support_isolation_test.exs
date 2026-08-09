defmodule Aiur.TestSupportIsolationTest do
  @moduledoc """
  Regression guard for the per-test log/state isolation that `Aiur.TestSupport`
  sets up (fix/ci-flaky-tests).

  `SessionHandle` resume files and per-issue logs live under `Paths.log_root_dir/0`,
  which defaults to the shared `<cwd>/log`. A leaked `<repo>.<id>.session.json`
  there makes the agent runner resume a prior thread instead of cold-starting —
  the order-dependent `core_test` flakiness that only surfaces in per-file/subset
  runs (the full suite CI runs happens to mask it). `TestSupport.setup` points
  `:log_file` at the per-test workflow root to close that leak; if that line is
  ever removed the full suite still passes, so this invariant needs its own
  assertion to catch the regression.

  The pause-store assertion likewise protects cwd-changing tests from selecting
  a different implicit production store during teardown.
  """
  use Aiur.TestSupport

  alias Aiur.Config.Paths
  alias Aiur.Orchestrator.GlobalPauseStore

  test "log_root_dir is isolated to the per-test workflow root, not <cwd>/log" do
    log_root = Paths.log_root_dir()

    refute log_root == Path.join(File.cwd!(), "log")
    assert String.ends_with?(log_root, "/log")
    assert String.contains?(log_root, "aiur-elixir-tests")
  end

  test "global pause persistence is isolated to the per-test workflow root" do
    path = GlobalPauseStore.path_for()

    assert path == Application.fetch_env!(:aiur, :global_pause_store_path)
    assert String.contains?(path, "aiur-elixir-tests")
    assert String.ends_with?(path, "/state/global-pause.json")
    assert {:ok, %{globally_paused: false}} = GlobalPauseStore.load()

    assert :ok =
             GlobalPauseStore.save(%{
               globally_paused: true,
               paused_at: DateTime.utc_now(),
               source: "test"
             })

    assert {:ok, %{globally_paused: true, source: "test"}} = GlobalPauseStore.load()
  end

  test "process lifecycle waits synchronize on DOWN instead of polling" do
    test_support = File.read!(Path.expand("../support/test_support.exs", __DIR__))
    refute test_support =~ "Process.sleep("

    process = spawn(fn -> receive do: (:stop -> :ok) end)
    waiter = Task.async(fn -> Aiur.TestSupport.await_process_down(process, 1_000) end)

    assert Task.yield(waiter, 0) == nil
    send(process, :stop)
    assert {:ok, :ok} = Task.yield(waiter, 1_000)
  end
end
