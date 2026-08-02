defmodule Aiur.OpenAICompat.BalanceBaselineTest do
  use ExUnit.Case, async: true

  alias Aiur.OpenAICompat.BalanceBaseline

  defp baseline_path do
    dir = Path.join(System.tmp_dir!(), "aiur-balance-baseline-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, "balance-baseline.json")
  end

  test "path sits beside the active workflow configuration" do
    previous = Application.get_env(:aiur, :workflow_file_path)

    try do
      Application.put_env(:aiur, :workflow_file_path, "/tmp/aiur-1532/.aiur/config")
      assert BalanceBaseline.path() == "/tmp/aiur-1532/.aiur/balance-baseline.json"
    after
      if is_nil(previous) do
        Application.delete_env(:aiur, :workflow_file_path)
      else
        Application.put_env(:aiur, :workflow_file_path, previous)
      end
    end
  end

  test "the first observed balance seeds and persists the baseline" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    assert {50.0, true} = BalanceBaseline.resolve(:deepseek, 50.0, opts)
    assert BalanceBaseline.persisted_baseline(:deepseek, path) == 50.0

    # A later observation reads the persisted baseline, never re-seeding.
    assert {50.0, false} = BalanceBaseline.resolve(:deepseek, 49.05, opts)
    assert BalanceBaseline.persisted_baseline(:deepseek, path) == 50.0
  end

  test "an explicit configured initial deposit takes precedence and needs no seeding" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{"deepseek" => %{"balance_baseline" => 100.0}}]

    assert {100.0, false} = BalanceBaseline.resolve(:deepseek, 80.0, opts)
    assert BalanceBaseline.persisted_baseline(:deepseek, path) == nil
  end

  test "a zero first observation establishes nothing so a later positive one can seed" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    assert BalanceBaseline.resolve(:deepseek, 0.0, opts) == nil
    assert BalanceBaseline.persisted_baseline(:deepseek, path) == nil

    assert {25.0, true} = BalanceBaseline.resolve(:deepseek, 25.0, opts)
  end

  test "a positive first observation seeds a baseline for any provider" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    # The module is generic; the probe only asks it about DeepSeek, but any
    # provider with a positive first balance and no baseline seeds.
    assert {77.5, true} = BalanceBaseline.resolve(:openrouter, 77.5, opts)
    assert BalanceBaseline.persisted_baseline(:openrouter, path) == 77.5
  end

  test "persisted baselines are keyed per provider" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    assert {10.0, true} = BalanceBaseline.resolve(:deepseek, 10.0, opts)
    assert BalanceBaseline.persisted_baseline(:deepseek, path) == 10.0
    assert BalanceBaseline.persisted_baseline(:openrouter, path) == nil
  end
end
