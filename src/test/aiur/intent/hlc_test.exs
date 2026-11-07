defmodule Aiur.Intent.HlcTest do
  use ExUnit.Case, async: true

  alias Aiur.Intent.Hlc

  setup do
    dir = Path.join(System.tmp_dir!(), "hlc-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    {:ok, dir: dir, clock: start_supervised!({Agent, fn -> 1_000_000 end}, id: :clock)}
  end

  defp start(ctx, name) do
    now_fun = fn -> Agent.get(ctx.clock, & &1) end
    start_supervised!({Hlc, dir: ctx.dir, now_fun: now_fun, name: name}, id: name)
  end

  test "first tick persists {now, 0}; same millisecond bumps the counter", ctx do
    start(ctx, :h1)
    assert {:ok, {1_000_000, 0}} = Hlc.tick(:h1)
    assert {:ok, {1_000_000, 1}} = Hlc.tick(:h1)
    assert %{"wall_ms" => 1_000_000, "counter" => 1} = ctx.dir |> Path.join("hlc.json") |> File.read!() |> Jason.decode!()
  end

  test "restart with the wall clock set back 5 minutes stays above the last persisted value", ctx do
    File.mkdir_p!(ctx.dir)
    File.write!(Path.join(ctx.dir, "hlc.json"), Jason.encode!(%{wall_ms: 1_000_000, counter: 3}))
    Agent.update(ctx.clock, fn _ -> 1_000_000 - 300_000 end)
    start(ctx, :h3)
    assert {:ok, {1_000_000, 4}} = Hlc.tick(:h3)
  end

  test "a persisted value is never reissued after restart", ctx do
    File.mkdir_p!(ctx.dir)
    File.write!(Path.join(ctx.dir, "hlc.json"), Jason.encode!(%{wall_ms: 2_000_000, counter: 7}))
    Agent.update(ctx.clock, fn _ -> 2_000_000 end)
    start(ctx, :h4)
    assert {:ok, {2_000_000, 8}} = Hlc.tick(:h4)
  end

  test "corrupt file is quarantined and the clock starts from now", ctx do
    File.mkdir_p!(ctx.dir)
    File.write!(Path.join(ctx.dir, "hlc.json"), "not json")
    start(ctx, :h5)
    assert {:ok, {1_000_000, 0}} = Hlc.tick(:h5)
    assert ctx.dir |> File.ls!() |> Enum.any?(&String.contains?(&1, "hlc.json.corrupt-"))
  end

  test "observe holds a remote 61s ahead and applies one 60s ahead", ctx do
    start(ctx, :h6)
    assert Hlc.observe(:h6, {1_061_000, 0}) == :held
    assert {:ok, {1_000_000, 0}} = Hlc.tick(:h6)
    assert Hlc.observe(:h6, {1_060_000, 4}) == :ok
    assert {:ok, {1_060_000, 6}} = Hlc.tick(:h6)
  end

  test "counter overflow is refused and leaves the clock unchanged", ctx do
    File.mkdir_p!(ctx.dir)
    File.write!(Path.join(ctx.dir, "hlc.json"), Jason.encode!(%{wall_ms: 1_000_000, counter: 2_147_483_647}))
    start(ctx, :h8)
    assert {:error, :hlc_counter_overflow} = Hlc.tick(:h8)
    assert {:error, :hlc_counter_overflow} = Hlc.tick(:h8)
  end
end
