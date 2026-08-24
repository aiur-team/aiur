defmodule Aiur.OpenAICompat.BalanceBaselineTest do
  # The module reads global app env (state-dir override, backend configs), so
  # these tests must not run concurrently with each other.
  use ExUnit.Case, async: false

  alias Aiur.OpenAICompat.BalanceBaseline

  defp baseline_path do
    dir = Aiur.TestSupport.tmp_root!("aiur-balance-baseline")
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
    dir = Aiur.TestSupport.tmp_root!("aiur-baseline-writefail")
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
    file = Aiur.TestSupport.tmp_root!("aiur-baseline-mkdirfail")
    File.write!(file, "not a directory")
    on_exit(fn -> File.rm(file) end)

    path = Path.join([file, "sub", "balance-baseline.json"])
    opts = [path: path, backend_configs: %{}]

    assert BalanceBaseline.resolve(:deepseek, 50.0, opts) == nil
    assert BalanceBaseline.persisted_baseline(:deepseek, path) == nil
  end

  # Spend is `baseline - remaining`, so a remaining balance above the baseline
  # would be negative consumption. The only thing that produces it is a top-up
  # recorded after the baseline was, which used to strand the meter at 0%
  # against a much larger balance until an operator deleted the ledger by hand.
  test "a persisted baseline below the observed balance is reseeded in place" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    assert {1.43, true} = BalanceBaseline.resolve(:deepseek, 1.43, opts)
    assert {1.43, false} = BalanceBaseline.resolve(:deepseek, 1.20, opts)

    # The top-up lands: the stale baseline is replaced by the observed balance
    # and reports itself as freshly seeded, so this observation renders
    # dollar-only rather than a fabricated 0% spend.
    assert {8.55, true} = BalanceBaseline.resolve(:deepseek, 8.55, opts)

    # And it is durable, not just in-memory: the next observation reads the
    # reseeded anchor and resumes reporting real spend against it.
    assert BalanceBaseline.persisted_baseline(:deepseek, path) == 8.55
    assert {8.55, false} = BalanceBaseline.resolve(:deepseek, 6.84, opts)

    # Replacing the anchor discards the only record of what spend was measured
    # against, so the entry keeps the amount it displaced.
    assert %{"previous_amount" => 1.43, "reseeded_at" => reseeded_at} = entry(path, :deepseek)
    assert is_binary(reseeded_at)
  end

  # A balance is dollars and cents. Sub-cent drift is float noise, not a
  # top-up, and reseeding on it would rewrite the ledger and hold the meter at
  # "no consumption evidence yet" on every probe cycle, forever.
  test "sub-cent drift above the baseline does not reseed" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    assert {50.0, true} = BalanceBaseline.resolve(:deepseek, 50.0, opts)
    recorded_at = recorded_at(path, :deepseek)

    assert {50.0, false} = BalanceBaseline.resolve(:deepseek, 50.005, opts)
    assert BalanceBaseline.persisted_baseline(:deepseek, path) == 50.0
    assert recorded_at(path, :deepseek) == recorded_at

    # A real top-up still clears the threshold.
    assert {60.0, true} = BalanceBaseline.resolve(:deepseek, 60.0, opts)
  end

  # Same best-effort contract as a failed first seed: the meter degrades to
  # dollar-only rather than raising through the probe. GitHub runners are not
  # root, so the read-only bit holds.
  test "a reseed that cannot be persisted degrades to dollar-only" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    assert {1.43, true} = BalanceBaseline.resolve(:deepseek, 1.43, opts)

    File.chmod!(path, 0o444)
    on_exit(fn -> File.chmod(path, 0o644) end)

    assert BalanceBaseline.resolve(:deepseek, 8.55, opts) == nil
    assert BalanceBaseline.persisted_baseline(:deepseek, path) == 1.43
  end

  test "a baseline exactly level with the observed balance is not reseeded" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    assert {50.0, true} = BalanceBaseline.resolve(:deepseek, 50.0, opts)
    # Re-reading the seeding observation is not a top-up; it must not churn the
    # ledger's `recorded_at` on every probe.
    recorded_at = recorded_at(path, :deepseek)
    assert {50.0, false} = BalanceBaseline.resolve(:deepseek, 50.0, opts)
    assert recorded_at(path, :deepseek) == recorded_at
  end

  # A reseed is only ever an upgrade. A drained account reads 100%, and must not
  # re-anchor itself to zero and start over at 0%.
  test "a zero observation never reseeds a positive baseline" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    assert {50.0, true} = BalanceBaseline.resolve(:deepseek, 50.0, opts)
    assert {50.0, false} = BalanceBaseline.resolve(:deepseek, 0.0, opts)
    assert BalanceBaseline.persisted_baseline(:deepseek, path) == 50.0
  end

  test "a reseed leaves other providers' baselines untouched" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    assert {1.43, true} = BalanceBaseline.resolve(:deepseek, 1.43, opts)
    assert {20.0, true} = BalanceBaseline.resolve(:openrouter, 20.0, opts)
    assert {8.55, true} = BalanceBaseline.resolve(:deepseek, 8.55, opts)

    assert BalanceBaseline.persisted_baseline(:openrouter, path) == 20.0
  end

  defp entry(path, provider) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["baselines", Atom.to_string(provider)])
  end

  defp recorded_at(path, provider), do: Map.get(entry(path, provider), "recorded_at")

  # The ledger is read-modify-written whole, so an unserialized seed drops the
  # other provider's entry. This is the failure the `:global` lock is for, and
  # it was live: the lock id keyed its *requester* on the path, and `:global`
  # grants a lock whose requester matches the one already held — so two probes
  # on the same ledger both took it.
  test "concurrent seeds for different providers on one ledger keep both entries" do
    path = baseline_path()
    opts = [path: path, backend_configs: %{}]

    [:deepseek, :openrouter]
    |> Enum.map(fn provider -> Task.async(fn -> BalanceBaseline.resolve(provider, 10.0, opts) end) end)
    |> Task.await_many(5_000)

    assert BalanceBaseline.persisted_baseline(:deepseek, path) == 10.0
    assert BalanceBaseline.persisted_baseline(:openrouter, path) == 10.0
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
