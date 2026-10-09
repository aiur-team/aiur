defmodule Aiur.SystemPriorityTest do
  use ExUnit.Case, async: false
  alias Aiur.{SystemCpu, SystemLoad, SystemPriority}

  setup do
    saved = for key <- [:proc_self_stat_source_override, :proc_stat_source_override], do: {key, Application.get_env(:aiur, key)}

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
      Application.put_env(:aiur, :proc_stat_source_override, fn -> {:ok, "cpu 0 100 0 0\nprocs_running 26\n"} end)
      assert SystemPriority.nice() == nice
      snapshot = SystemCpu.snapshot()
      assert snapshot.daemon_nice == nice
      headroom = SystemCpu.headroom(%{snapshot | total: 0, nice: 0}, snapshot)
      assert SystemLoad.gate_signal(25.0, headroom, 16) == if(nice == 0, do: 9.0, else: 25.0)
      assert headroom.reclaimable_percent == if(nice == 0, do: 100.0, else: 0.0)
      changed = SystemCpu.headroom(%{snapshot | total: 0, nice: 0, daemon_nice: :unavailable}, snapshot)
      assert changed.daemon_nice == :unavailable
      assert changed.reclaimable_percent == 0.0
      assert SystemLoad.gate_signal(25.0, changed, 16) == 25.0
    end
  end

  test "unreadable or malformed self stat cannot discount aggregate nice CPU" do
    Application.put_env(:aiur, :proc_stat_source_override, fn -> {:ok, "cpu 0 100 0 0\nprocs_running 26\n"} end)

    for result <- [{:error, :enoent}, {:ok, "garbage"}, {:ok, stat(20)}, {:ok, "1 (beam) R"}] do
      Application.put_env(:aiur, :proc_self_stat_source_override, fn -> result end)
      assert SystemPriority.nice() == :unavailable
      snapshot = SystemCpu.snapshot()
      assert snapshot.daemon_nice == :unavailable
      headroom = SystemCpu.headroom(%{snapshot | total: 0, nice: 0}, snapshot)
      assert headroom.reclaimable_percent == 0.0
      assert SystemLoad.gate_signal(25.0, headroom, 16) == 25.0
      assert SystemLoad.discount_reason(headroom) == :unavailable
    end
  end

  defp stat(nice) do
    fields = List.duplicate("0", 20) |> List.replace_at(0, "R") |> List.replace_at(15, "20") |> List.replace_at(16, Integer.to_string(nice))
    "1 (beam test ) name) #{Enum.join(fields, " ")}\n"
  end
end
