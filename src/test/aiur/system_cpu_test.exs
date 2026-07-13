defmodule Aiur.SystemCpuTest do
  use ExUnit.Case, async: false

  alias Aiur.SystemCpu

  setup do
    previous = Application.get_env(:aiur, :proc_stat_source_override)
    on_exit(fn -> restore_app_env(:proc_stat_source_override, previous) end)
    :ok
  end

  test "parses aggregate counters and runnable pressure" do
    Application.put_env(:aiur, :proc_stat_source_override, fn ->
      {:ok, "cpu  100 5 40 800 20 2 3 4 0 0\nprocs_running 3\n"}
    end)

    assert %{total: 974, idle: 800, runnable: 3} = SystemCpu.snapshot()
  end

  test "calculates idle percentage from consecutive snapshots" do
    previous = %{total: 1_000, idle: 700, runnable: 4}
    current = %{total: 1_200, idle: 860, runnable: 2}

    assert %{idle_percent: 80.0, runnable: 2} = SystemCpu.headroom(previous, current)
  end

  test "requires a prior positive monotonic delta" do
    current = %{total: 1_000, idle: 700, runnable: 2}

    assert SystemCpu.headroom(nil, current) == :unavailable
    assert SystemCpu.headroom(current, current) == :unavailable
    assert SystemCpu.headroom(current, %{current | total: 999}) == :unavailable
    assert SystemCpu.headroom(current, %{current | total: 1_100, idle: 900}) == :unavailable
  end

  test "returns unavailable for missing or malformed procfs data" do
    Application.put_env(:aiur, :proc_stat_source_override, fn -> {:error, :enoent} end)
    assert SystemCpu.snapshot() == :unavailable

    Application.put_env(:aiur, :proc_stat_source_override, fn -> {:ok, "garbage"} end)
    assert SystemCpu.snapshot() == :unavailable
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
