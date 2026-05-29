defmodule Aiur.Sandbox.EventFlowDemoTest do
  use Aiur.TestSupport

  alias Aiur.Sandbox.EventFlowDemo

  test "function_a/0 returns the event-flow seed value" do
    assert EventFlowDemo.function_a() == 42
  end

  test "function_b/0 increments function_a/0" do
    assert EventFlowDemo.function_b() == 43
  end
end
