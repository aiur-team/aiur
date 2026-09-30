defmodule Aiur.Sandbox.EventFlowDemoTest do
  use Aiur.TestSupport

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a returns 42 without console output" do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert EventFlowDemo.function_a() == 42
           end) == ""
  end
end
