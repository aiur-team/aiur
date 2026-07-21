defmodule Aiur.Sandbox.EventFlowDemoTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a logs and returns 42" do
    assert capture_io(fn -> assert EventFlowDemo.function_a() == 42 end) ==
             "function_a returning 42\n"
  end
end
