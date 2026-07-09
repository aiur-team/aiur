defmodule Aiur.PeriodicWorkerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defmodule TestWorker do
    use Aiur.PeriodicWorker

    @impl GenServer
    def init(opts) do
      state = %{
        interval_ms: Keyword.get(opts, :interval_ms, 25),
        start_paused?: Keyword.get(opts, :start_paused?, true),
        notify: Keyword.fetch!(opts, :notify),
        tick_fun: Keyword.fetch!(opts, :tick_fun)
      }

      {:ok, Aiur.PeriodicWorker.schedule_first_tick(state)}
    end

    @impl Aiur.PeriodicWorker
    def tick(state), do: state.tick_fun.(state)
  end

  defp start_worker(opts) do
    opts = Keyword.put_new(opts, :notify, self())
    start_supervised!({TestWorker, opts})
  end

  test "start_paused?: true schedules no first tick" do
    tick_fun = fn state ->
      send(state.notify, :tick_ran)
      state
    end

    start_worker(start_paused?: true, tick_fun: tick_fun)
    refute_receive :tick_ran, 200
  end

  test "start_paused?: false ticks and reschedules from next_delay_ms" do
    tick_fun = fn state ->
      send(state.notify, :tick_ran)
      Map.put(state, :next_delay_ms, 10)
    end

    start_worker(start_paused?: false, interval_ms: 10, tick_fun: tick_fun)

    assert_receive :tick_ran, 2000
    assert_receive :tick_ran, 2000
  end

  test "a raising tick logs, keeps state, and keeps the schedule alive" do
    tick_fun = fn state ->
      send(state.notify, :tick_ran)
      raise "boom"
    end

    pid = start_worker(start_paused?: true, interval_ms: 10, tick_fun: tick_fun)

    log =
      capture_log(fn ->
        send(pid, :tick)
        assert_receive :tick_ran, 2000
        # the rescued tick still rescheduled: the next tick arrives
        assert_receive :tick_ran, 2000
      end)

    assert log =~ "TestWorker tick raised: boom"
  end

  test "a throwing tick is caught and logged" do
    tick_fun = fn state ->
      send(state.notify, :tick_ran)
      throw(:boom)
    end

    pid = start_worker(start_paused?: true, tick_fun: tick_fun)

    log =
      capture_log(fn ->
        send(pid, :tick)
        assert_receive :tick_ran, 2000

        # A second tick drains the mailbox past the first tick's catch handler
        # (the worker processes messages serially), so its log line is emitted
        # before capture_log stops — the single-tick form raced the async log
        # on a loaded CI box.
        send(pid, :tick)
        assert_receive :tick_ran, 2000
      end)

    assert log =~ "TestWorker tick caught throw: :boom"
  end

  test "unknown messages are ignored without crashing" do
    tick_fun = fn state -> state end
    pid = start_worker(start_paused?: true, tick_fun: tick_fun)

    send(pid, :unexpected)

    assert %{start_paused?: true} = :sys.get_state(pid)
  end
end
