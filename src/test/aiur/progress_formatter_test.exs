defmodule Aiur.TestSupport.ProgressFormatterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.TestSupport.ProgressFormatter

  test "periodic reports name tests that started and have not finished" do
    test = %ExUnit.Test{name: :long_running_check, module: __MODULE__}
    state = %{running: %{}, report_interval_ms: nil}

    output =
      capture_io(fn ->
        {:noreply, active} = ProgressFormatter.handle_cast({:test_started, test}, state)
        {:noreply, _reported} = ProgressFormatter.handle_info(:report_running, active)
      end)

    assert output =~ "still-running tests:"
    assert output =~ "#{inspect(__MODULE__)} long_running_check"
  end

  test "completed tests are totaled by source file and flushed as a timing snapshot" do
    path = Path.join(System.tmp_dir!(), "coverage-test-times-#{System.unique_integer([:positive])}.tsv")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)

    state = %{running: %{}, file_timings: %{}, timings_path: path, report_interval_ms: nil}

    first = %ExUnit.Test{
      name: :first,
      module: __MODULE__,
      tags: %{file: "test/aiur/slow_test.exs"},
      time: 1_250_000
    }

    second = %ExUnit.Test{
      name: :second,
      module: __MODULE__,
      tags: %{file: "test/aiur/slow_test.exs"},
      time: 750_000
    }

    {:noreply, state} = ProgressFormatter.handle_cast({:test_finished, first}, state)
    {:noreply, state} = ProgressFormatter.handle_cast({:test_finished, second}, state)
    {:noreply, _state} = ProgressFormatter.handle_info(:report_running, state)

    assert File.read!(path) ==
             "path\ttests\ttotal_us\tmax_us\n" <>
               "test/aiur/slow_test.exs\t2\t2000000\t1250000\n"
  end
end
