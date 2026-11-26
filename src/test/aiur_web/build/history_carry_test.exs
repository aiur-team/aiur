defmodule AiurWeb.Build.HistoryCarryTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.ProviderHealth
  alias AiurWeb.Build.HistoryCarry

  @all MapSet.new([:history, :health])
  @earlier 1_000_000
  @later 2_000_000

  test "a successful history read records its time" do
    assert {parts([row(7)]), @later} == HistoryCarry.carry(parts(), parts([row(7)]), @all, @earlier, @later)
  end

  test "a failed read keeps the last good rows, stale at the last successful read time" do
    failed = %{parts() | history: {:error, :timeout}, health: {:error, :timeout}}
    {carried, read_at} = HistoryCarry.carry(parts([row(7)]), failed, @all, @earlier, @later)
    assert read_at == @earlier
    assert {:ok, %{rows: %{7 => _}, health: %ProviderHealth{state: :stale, failure: :timeout} = health}} = carried.history
    assert DateTime.to_unix(health.observed_at, :millisecond) == @earlier
    assert %ProviderHealth{state: :stale, failure: :timeout} = carried.health

    # A second failure keeps the first good read's time rather than restamping it.
    assert {again, @earlier} = HistoryCarry.carry(carried, %{failed | health: {:error, :read_failed}}, @all, read_at, @later + 1)
    assert again.health.observed_at == health.observed_at
  end

  test "a store that reports itself unavailable is shown as such, not masked by old rows" do
    %ProviderHealth{} = healthy = health()
    down = %{healthy | state: :unavailable, failure: :structurally_invalid}
    reported = %{parts() | health: down, history: {:error, down}}
    assert {^reported, @earlier} = HistoryCarry.carry(parts([row(7)]), reported, @all, @earlier, @later)
  end

  test "a read that did not refresh history leaves it and its time alone" do
    failed = %{parts() | history: {:error, :timeout}}
    assert {^failed, @earlier} = HistoryCarry.carry(parts([row(7)]), failed, MapSet.new([:now]), @earlier, @later)
  end
end
