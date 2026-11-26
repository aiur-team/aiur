defmodule Aiur.Orchestrator.UnresponsiveWatchdogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.Orchestrator.UnresponsiveWatchdog

  # open-games, 2026-11-20: status calls to the orchestrator timed out for
  # minutes and only a restart cleared it, but the stall alert lives inside the
  # orchestrator, so nothing said where it was stuck. The watchdog reads it from
  # outside and must name the stack without calling it.

  @blocked [
    current_function: {:gen, :do_call, 4},
    message_queue_len: 412,
    current_stacktrace: [{:gen, :do_call, 4, [file: ~c"gen.erl", line: 240]}, {Aiur.Orchestrator.Dispatcher, :poll, 2, [file: ~c"lib/aiur/orchestrator/dispatcher.ex", line: 99]}]
  ]
  @idle [current_function: {:gen_server, :loop, 7}, message_queue_len: 0, current_stacktrace: []]

  setup do
    test_pid = self()
    {:ok, readings} = Agent.start_link(fn -> [] end)
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    state = %{
      interval_ms: 15_000,
      whereis: fn -> test_pid end,
      info: fn ^test_pid, _keys -> Agent.get_and_update(readings, fn [next | rest] -> {next, rest} end) end,
      alert: fn topic, opts -> send(test_pid, {:alert, topic, opts[:message]}) end,
      now_ms: fn -> Agent.get(clock, & &1) end,
      previous_busy?: false,
      episode: nil
    }

    feed = fn samples -> Agent.update(readings, fn _ -> samples end) end
    tick = fn ms -> Agent.update(clock, &(&1 + ms)) end
    %{state: state, feed: feed, tick: tick}
  end

  test "two busy samples in a row log the stack and raise one alert", %{state: state, feed: feed, tick: tick} do
    feed.([@blocked, @blocked, @blocked])

    log =
      capture_log(fn ->
        state = UnresponsiveWatchdog.sample(state)
        refute_received {:alert, _topic, _message}, "one busy sample is ordinary work"

        tick.(15_000)
        state = UnresponsiveWatchdog.sample(state)
        tick.(15_000)
        _state = UnresponsiveWatchdog.sample(state)
      end)

    assert_received {:alert, "system.orchestrator.unresponsive", message}
    assert message =~ "412 messages waiting"
    refute_received {:alert, "system.orchestrator.unresponsive", _message}, "one alert per episode"
    assert log =~ "message_queue_len=412"
    assert log =~ "Aiur.Orchestrator.Dispatcher.poll/2"
  end

  test "the episode resolves once the orchestrator is idle again", %{state: state, feed: feed, tick: tick} do
    feed.([@blocked, @blocked, @idle])

    capture_log(fn ->
      state = state |> UnresponsiveWatchdog.sample() |> UnresponsiveWatchdog.sample()
      tick.(45_000)
      state = UnresponsiveWatchdog.sample(state)
      assert state.episode == nil
    end)

    assert_received {:alert, "system.orchestrator.unresponsive", _message}
    assert_received {:alert, "system.orchestrator.unresponsive.resolved", resolved}
    assert resolved =~ "about 45s"
  end

  test "a busy sample between idle ones is not an episode", %{state: state, feed: feed} do
    feed.([@blocked, @idle, @blocked, @idle])
    Enum.reduce(1..4, state, fn _n, state -> UnresponsiveWatchdog.sample(state) end)
    refute_received {:alert, _topic, _message}
  end

  test "a missing orchestrator is not reported as unresponsive", %{state: state} do
    state = %{state | whereis: fn -> nil end}
    assert UnresponsiveWatchdog.sample(UnresponsiveWatchdog.sample(state)).episode == nil
    refute_received {:alert, _topic, _message}
  end
end
