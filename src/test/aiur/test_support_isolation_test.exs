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
  """
  use Aiur.TestSupport

  alias Aiur.Config.Paths

  test "log_root_dir is isolated to the per-test workflow root, not <cwd>/log" do
    log_root = Paths.log_root_dir()

    refute log_root == Path.join(File.cwd!(), "log")
    assert String.ends_with?(log_root, "/log")
    assert String.contains?(log_root, "aiur-elixir-tests")
  end
end
