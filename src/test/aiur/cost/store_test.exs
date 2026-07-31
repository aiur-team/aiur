defmodule Aiur.Cost.StoreTest do
  use ExUnit.Case, async: false

  alias Aiur.Cost.Store

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur-cost-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prior = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(tmp, "aiur.log"))

    id = "cost-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Store.stop(id)
      if prior, do: Application.put_env(:aiur, :log_file, prior), else: Application.delete_env(:aiur, :log_file)
      File.rm_rf!(tmp)
    end)

    %{id: id}
  end

  defp obs(thread_id, input, cached, output, total, window) do
    %{
      thread_id: thread_id,
      input_tokens: input,
      cached_input_tokens: cached,
      output_tokens: output,
      total_tokens: total,
      context_window: window,
      meta: %{
        provider: :claude,
        resolved_model: "claude-opus-4-8",
        relationship_revision: "claude-remote-control-2026-07",
        pricing_effective_date: ~D[2026-07-30],
        context_tier: nil
      }
    }
  end

  test "accumulates tokens and computes context percent + usd", %{id: id} do
    :ok = Store.record(id, obs("a", 60_000, 30_000, 6_000, 66_000, 200_000))
    snap = Store.snapshot(id)

    assert snap.cost.input_tokens == 60_000
    assert snap.cost.cached_input_tokens == 30_000
    assert snap.cost.output_tokens == 6_000
    assert snap.context.tokens == 66_000
    assert snap.context.limit == 200_000
    assert snap.context.percent_used == 33
    # Exact catalog math (claude-opus: input $5.00/M, cached $0.50/M, output $25.00/M):
    # non-cached input (60k-30k)=30k * 5.00 + cached 30k * 0.50 + output 6k * 25.00
    # = 0.15 + 0.015 + 0.15 = 0.315
    assert Decimal.equal?(snap.cost.usd, Decimal.new("0.315"))
  end

  test "running total spans threads (a new session keeps the total)", %{id: id} do
    :ok = Store.record(id, obs("a", 60_000, 0, 0, 66_000, 200_000))
    :ok = Store.record(id, obs("b", 40_000, 0, 0, 44_000, 200_000))
    snap = Store.snapshot(id)

    assert snap.cost.input_tokens == 100_000
    # context tracks the active (latest) thread window
    assert snap.context.tokens == 44_000
    assert snap.context.percent_used == 22
  end

  test "absolute high-water never decreases within a thread", %{id: id} do
    :ok = Store.record(id, obs("a", 60_000, 0, 0, 66_000, 200_000))
    :ok = Store.record(id, obs("a", 50_000, 0, 0, 55_000, 200_000))
    assert Store.snapshot(id).cost.input_tokens == 60_000
  end

  test "total persists across a restart", %{id: id} do
    :ok = Store.record(id, obs("a", 60_000, 30_000, 6_000, 66_000, 200_000))
    before = Store.snapshot(id)
    :ok = Store.stop(id)

    :ok = Store.attach(id)
    restored = Store.snapshot(id)

    assert restored.cost.input_tokens == before.cost.input_tokens
    assert restored.cost.cached_input_tokens == before.cost.cached_input_tokens
    assert restored.context.percent_used == before.context.percent_used
    assert Decimal.equal?(restored.cost.usd, before.cost.usd)
  end
end
