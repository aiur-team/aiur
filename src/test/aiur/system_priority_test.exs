defmodule Aiur.SystemPriorityTest do
  use ExUnit.Case, async: false
  alias Aiur.{SystemCpu, SystemPriority}

  setup do
    saved = for key <- [:proc_self_stat_source_override, :proc_stat_source_override, :background_cpu_source_override], do: {key, Application.get_env(:aiur, key)}

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:aiur, key)
        {key, value} -> Application.put_env(:aiur, key, value)
      end)
    end)

    :ok
  end

  test "samples the daemon nice field despite spaces and closing parentheses in comm" do
    for nice <- [0, 5, -5, 19, -20] do
      Application.put_env(:aiur, :proc_self_stat_source_override, fn -> {:ok, stat(nice)} end)
      assert SystemPriority.nice() == nice
    end

    assert {:ok, %{nice: 15, ticks: 30, start: 9}} = SystemPriority.parse_stat(stat(15, utime: 10, stime: 20, start: 9))
  end

  test "unreadable or malformed self stat is unavailable, not nice 0" do
    for result <- [{:error, :enoent}, {:ok, "garbage"}, {:ok, stat(20)}, {:ok, "1 (beam) R"}] do
      Application.put_env(:aiur, :proc_self_stat_source_override, fn -> result end)
      assert SystemPriority.nice() == :unavailable
    end
  end

  test "snapshots embed the latest background reading" do
    reading = %{epoch: :e, daemon_nice: 5, ticks: 3, cpu_total: 100, sampled_at_ms: 0}
    Application.put_env(:aiur, :proc_stat_source_override, fn -> {:ok, "cpu 0 100 0 0\nprocs_running 26\n"} end)
    Application.put_env(:aiur, :background_cpu_source_override, fn -> reading end)
    assert %{total: 100, nice: 100, background: ^reading} = SystemCpu.snapshot()

    Application.put_env(:aiur, :background_cpu_source_override, fn -> :unavailable end)
    assert %{background: :unavailable} = SystemCpu.snapshot()
  end

  defp stat(nice, opts \\ []) do
    fields =
      List.duplicate("0", 20)
      |> List.replace_at(0, "R")
      |> List.replace_at(11, "#{Keyword.get(opts, :utime, 0)}")
      |> List.replace_at(12, "#{Keyword.get(opts, :stime, 0)}")
      |> List.replace_at(15, "20")
      |> List.replace_at(16, Integer.to_string(nice))
      |> List.replace_at(19, "#{Keyword.get(opts, :start, 0)}")

    "1 (beam test ) name) #{Enum.join(fields, " ")}\n"
  end
end
