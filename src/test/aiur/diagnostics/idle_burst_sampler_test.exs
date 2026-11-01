defmodule Aiur.Diagnostics.IdleBurstSamplerTest do
  use ExUnit.Case, async: true

  alias Aiur.Diagnostics.IdleBurstSampler

  test "strict trigger captures eight stacks together for only the five hottest processes" do
    pids = Enum.to_list(1..8)
    {opts, reads} = source(pids, fn pid, time -> if time < 200, do: 0, else: pid * 100_000 end)
    result = IdleBurstSampler.run(opts ++ [duration_ms: 1_000, max_bursts: 1])

    assert result.stopped == :max_bursts
    assert [%{at_ms: 200, window_ms: 200, processes: processes, samples: samples}] = result.bursts
    assert Enum.map(processes, &{&1.pid, &1.reductions}) == [{8, 800_000}, {7, 700_000}, {6, 600_000}, {5, 500_000}, {4, 400_000}]
    assert Enum.map(samples, & &1.at_ms) == [225, 250, 275, 300, 325, 350, 375, 400]
    assert Enum.all?(samples, fn sample -> Enum.map(sample.stacks, &elem(&1, 0)) == [8, 7, 6, 5, 4] end)
    assert hd(samples).stacks == Enum.map([8, 7, 6, 5, 4], &{&1, {:current_stacktrace, [{__MODULE__, :work, [&1, 225], []}]}})
    assert Enum.count(reads.(), fn {_pid, key, _time} -> key == :current_stacktrace end) == 40
  end

  test "sampler excludes itself, ignores new and exited processes, and does not trigger at equality" do
    {opts, reads} =
      source([self(), :equal, :new, :exited], fn
        :new, 0 -> nil
        :new, _ -> 9_000_000
        :exited, 0 -> 0
        :exited, _ -> nil
        :equal, time -> time * 1_500
        _pid, _time -> 9_000_000
      end)

    assert %{bursts: [], windows: 2, stopped: :duration, elapsed_ms: 400} = IdleBurstSampler.run(opts ++ [duration_ms: 400])
    refute Enum.any?(reads.(), fn {pid, _, _} -> pid == self() end)
    refute Enum.any?(reads.(), fn {_, key, _} -> key == :current_stacktrace end)
  end

  test "uses elapsed time when scheduler delay stretches a window" do
    {opts, _reads} = source([:worker], fn _, time -> time * 1_000 end, 200)
    assert %{bursts: [], windows: 1, elapsed_ms: 400} = IdleBurstSampler.run(opts ++ [duration_ms: 400])
  end

  test "rebaselines after a capture and retains repeated bursts without counting sampling time" do
    {opts, _reads} = source([:worker], fn _, time -> if time < 200, do: 0, else: div(time, 200) * 400_000 end)
    result = IdleBurstSampler.run(opts ++ [duration_ms: 800])
    assert result.windows == 2
    assert Enum.map(result.bursts, &{&1.at_ms, &1.window_ms}) == [{200, 200}, {600, 200}]
    assert Enum.map(result.bursts, &length(&1.samples)) == [8, 8]
  end

  test "deadline truncates capture and records processes that exit during stack sampling" do
    {opts, _reads} = source([:worker], fn _, time -> time * 2_000 end)
    # Exit after the triggering reduction read, including the post-capture baseline.
    info = Keyword.fetch!(opts, :info)
    opts = Keyword.put(opts, :info, fn pid, key -> if key == :reductions and clock() <= 200, do: info.(pid, key), else: nil end)

    assert %{bursts: [%{samples: [%{at_ms: 225, stacks: [worker: nil]}, %{at_ms: 250, stacks: [worker: nil]}]}], elapsed_ms: 250} =
             IdleBurstSampler.run(opts ++ [duration_ms: 250])
  end

  test "rejects invalid bounds before polling" do
    assert_raise ArgumentError, fn -> IdleBurstSampler.run(duration_ms: 0) end
    assert_raise ArgumentError, fn -> IdleBurstSampler.run(max_bursts: -1) end
  end

  defp source(pids, reductions, delay \\ 0) do
    Process.put({__MODULE__, :time}, 0)
    Process.put({__MODULE__, :reads}, [])

    info = fn pid, key ->
      time = clock()
      Process.put({__MODULE__, :reads}, [{pid, key, time} | Process.get({__MODULE__, :reads})])

      case key do
        :reductions -> reduction_info(reductions.(pid, time))
        :registered_name -> {:registered_name, []}
        :initial_call -> {:initial_call, {__MODULE__, :work, 0}}
        :current_stacktrace -> {:current_stacktrace, [{__MODULE__, :work, [pid, time], []}]}
      end
    end

    opts = [processes: fn -> pids end, info: info, clock: &clock/0, sleep: fn ms -> Process.put({__MODULE__, :time}, clock() + ms + delay) end]
    {opts, fn -> Process.get({__MODULE__, :reads}) end}
  end

  defp reduction_info(nil), do: nil
  defp reduction_info(count), do: {:reductions, count}

  defp clock, do: Process.get({__MODULE__, :time})
end
