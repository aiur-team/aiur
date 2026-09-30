defmodule Aiur.Sandbox.EventFlowDemoTest do
  use Aiur.TestSupport

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a returns 42 without console output" do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert EventFlowDemo.function_a() == 42
           end) == ""
  end

  test "function_b adds one to function_a's result" do
    assert EventFlowDemo.function_b() == 43
  end

  test "function_c squares function_b's result" do
    assert EventFlowDemo.function_c() == 1_849
  end
end
