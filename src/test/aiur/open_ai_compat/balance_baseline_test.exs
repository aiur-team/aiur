defmodule Aiur.OpenAICompat.BalanceBaselineTest do
  # The module reads global app env (state-dir override, backend configs), so
  # these tests must not run concurrently with each other.
  use ExUnit.Case, async: false

  alias Aiur.OpenAICompat.BalanceBaseline

  defp baseline_path do
    dir = Path.join(System.tmp_dir!(), "aiur-balance-baseline-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, "balance-baseline.json")
  end

  test "path sits under the daemon-private state dir, not the workflow config" do
    previous = Application.get_env(:aiur, :balance_baseline_state_dir)

    try do
      Application.put_env(:aiur, :balance_baseline_state_dir, "/tmp/aiur-1532/state")
      assert BalanceBaseline.path() == "/tmp/aiur-1532/state/balance-baseline.json"
    after
      if is_nil(previous) do
        Application.delete_env(:aiur, :balance_baseline_state_dir)
      else
        Application.put_env(:aiur, :balance_baseline_state_dir, previous)
      end
    end
  end

  test "resolve degrades to dollar-only when no durable path is available" do
    assert BalanceBaseline.resolve(:deepseek, 50.0, path: nil, backend_configs: %{}) == nil
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

  test "a failed baseline write degrades to dollar-only and never raises" do
    # The path is an existing directory, so the write raises EISDIR; the module
    # must swallow it and report no baseline rather than propagating a raise.
    dir = Path.join(System.tmp_dir!(), "aiur-baseline-writefail-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    opts = [path: dir, backend_configs: %{}]

    assert BalanceBaseline.resolve(:deepseek, 50.0, opts) == nil
    assert BalanceBaseline.persisted_baseline(:deepseek, dir) == nil
  end

  test "a baseline write whose directory cannot be created degrades to dollar-only and never raises" do
    # The path's intermediate directory cannot be created: its parent is an
    # existing *file*, so `File.mkdir_p!/1` fails with ENOTDIR. This is the
    # same failure shape as a read-only mount or full disk — `mkdir` itself
    # fails, before the file write — and the probe must swallow it rather than
    # propagate a raise up through the meter probe.
    file = Path.join(System.tmp_dir!(), "aiur-baseline-mkdirfail-#{System.unique_integer([:positive])}")
    File.write!(file, "not a directory")
    on_exit(fn -> File.rm(file) end)

    path = Path.join([file, "sub", "balance-baseline.json"])
    opts = [path: path, backend_configs: %{}]

    assert BalanceBaseline.resolve(:deepseek, 50.0, opts) == nil
    assert BalanceBaseline.persisted_baseline(:deepseek, path) == nil
  end

  test "concurrent resolve calls never raise and leave a valid single baseline" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    amounts = [50.0, 51.0, 52.0, 53.0]

    results =
      amounts
      |> Enum.map(fn amount -> Task.async(fn -> BalanceBaseline.resolve(:deepseek, amount, opts) end) end)
      |> Task.await_many(5_000)

    # Every caller resolves to a positive baseline (never nil, never a raise),
    # and the ledger stays a decodable JSON with a single positive baseline
    # that is one of the observed amounts. Note: this exercises the file under
    # cross-process contention, but strict seed-atomicity lives in the in-lock
    # re-check, which only serializes on nodes where `:global.trans` holds
    # (the daemon's distributed runtime); the refresh scheduler already
    # serializes observations, so seeding is single-writer in practice.
    persisted = BalanceBaseline.persisted_baseline(:deepseek, path)
    assert persisted != nil
    assert persisted in amounts

    assert Enum.all?(results, fn
             {amount, _freshly_seeded?} when is_number(amount) and amount > 0 -> true
             nil -> false
           end)
  end
end
