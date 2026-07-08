defmodule Aiur.GlobalLogIsolationTest do
  @moduledoc """
  Pins the suite-global `:log_file` isolation set in `config/config.exs`
  (test block). Without it, tests that never `use Aiur.TestSupport` — and
  the app's own boot (`Aiur.Events.IdGenerator` writes
  `<log_root>/<repo>.event_id` during init, before test_helper.exs runs) —
  persist into the shared `<cwd>/log`, where `System.unique_integer/1`
  identifier reuse across VM boots resurrects stale subscription state
  (the #687 ghost auto-resume flake class). Companion to the per-test
  guard in `Aiur.TestSupportIsolationTest`.
  """
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths

  test "global :log_file default lives under the per-run tmp root, not <cwd>/log" do
    log_file = Application.get_env(:aiur, :log_file)

    assert is_binary(log_file)
    assert String.starts_with?(log_file, System.tmp_dir!())
    assert log_file |> Path.dirname() |> Path.basename() =~ "aiur-test-logs-"
    refute String.starts_with?(log_file, File.cwd!())
  end

  test "log_root_dir/0 resolves under the system tmp dir, never <cwd>/log" do
    log_root = Paths.log_root_dir()

    assert String.starts_with?(log_root, System.tmp_dir!())
    refute log_root == Path.join(File.cwd!(), "log")
  end

  test "boot-time IdGenerator counter write landed in the isolation root" do
    dir = Path.dirname(Application.get_env(:aiur, :log_file))

    assert {:ok, entries} = File.ls(dir)
    assert Enum.any?(entries, &String.ends_with?(&1, ".event_id"))
  end
end
