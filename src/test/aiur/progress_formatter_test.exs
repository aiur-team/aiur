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
end
